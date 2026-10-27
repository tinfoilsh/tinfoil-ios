import Foundation
import OSLog

/// Where this device keeps the chats the harness does not store: a chat is
/// a thread in the harness's format, sent with each turn, and replaced by
/// the thread the run's final event returns.
protocol LocalThreadStore: AnyObject, Sendable {
    func list() async throws -> [ThreadSummary]
    func get(_ id: String) async throws -> StoredThread?
    /// Reads, changes, and writes one thread at a time, so concurrent runs
    /// of the same chat cannot lose each other's messages. Returning nil
    /// skips the write, as does a chat deleted in the meantime. Originals of
    /// the written thread's attachments are kept with it.
    @discardableResult
    func update(_ id: String, originals: Originals, _ change: @Sendable (StoredThread?) -> StoredThread?) async throws -> StoredThread?
    /// Stores a chat that arrives from elsewhere, such as the cloud, under
    /// its own id, even one deleted from this device before. A chat already
    /// stored under the id is kept, and nil is returned.
    func add(_ thread: StoredThread, originals: Originals) async throws -> StoredThread?
    func originals(_ id: String, attachmentIds: [String]) async throws -> Originals
    func delete(_ id: String) async throws
    @discardableResult
    func deleteAll() async throws -> Int
}

/// The chats of an account kept in encrypted files under the device's key,
/// or a signed-out caller's kept in memory for the app's lifetime.
actor DeviceThreadStore: LocalThreadStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    private struct Entry: Codable {
        var thread: Data
        var originals: Originals
    }

    private let directory: URL?
    private let encryptor: ChatEncryptor
    private var memory: [String: Entry] = [:]
    private var summaries: [String: ThreadSummary]?

    /// A store on disk under the account's directory, or in memory when
    /// there is none.
    init(directory: URL?, encryptor: ChatEncryptor = DeviceEncryptionService.shared) {
        self.directory = directory
        self.encryptor = encryptor
    }

    static func directory(userId: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let safe = userId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let url = support.appendingPathComponent("tinfoil", isDirectory: true)
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        return url
    }

    func list() async throws -> [ThreadSummary] {
        try await loadSummaries().values.sorted { $0.activityAt > $1.activityAt || ($0.activityAt == $1.activityAt && $0.id > $1.id) }
    }

    func get(_ id: String) async throws -> StoredThread? {
        try await entry(id).flatMap { StoredThread(data: $0.thread) }
    }

    @discardableResult
    func update(_ id: String, originals: Originals = [:], _ change: @Sendable (StoredThread?) -> StoredThread?) async throws -> StoredThread? {
        let current = try await get(id)
        guard var next = change(current) else { return nil }
        next.id = id
        var kept = try await entry(id)?.originals ?? [:]
        kept.merge(originals) { $1 }
        let ids = Set(next.attachments.map(\.id))
        kept = kept.filter { ids.contains($0.key) }
        try await write(id, Entry(thread: try next.data(), originals: kept))
        var listed = try await loadSummaries()
        listed[id] = next.summary
        summaries = listed
        return next
    }

    func add(_ thread: StoredThread, originals: Originals = [:]) async throws -> StoredThread? {
        if try await entry(thread.id) != nil { return nil }
        return try await update(thread.id, originals: originals) { _ in thread }
    }

    func originals(_ id: String, attachmentIds: [String]) async throws -> Originals {
        guard let kept = try await entry(id)?.originals else { return [:] }
        return kept.filter { attachmentIds.contains($0.key) }
    }

    func delete(_ id: String) async throws {
        if let directory {
            try? FileManager.default.removeItem(at: file(directory, id))
        }
        memory[id] = nil
        var listed = try await loadSummaries()
        listed[id] = nil
        summaries = listed
    }

    @discardableResult
    func deleteAll() async throws -> Int {
        let count = try await loadSummaries().count
        if let directory {
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        memory = [:]
        summaries = [:]
        return count
    }

    // MARK: - Files

    private static let threadExtension = "thread"

    private func file(_ directory: URL, _ id: String) -> URL {
        directory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: false)
            .appendingPathExtension(Self.threadExtension)
    }

    private func entry(_ id: String) async throws -> Entry? {
        guard let directory else { return memory[id] }
        let url = file(directory, id)
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        let envelope = try JSONDecoder().decode(EncryptedData.self, from: sealed)
        return try JSONDecoder().decode(Entry.self, from: try await encryptor.decryptData(envelope))
    }

    private func write(_ id: String, _ entry: Entry) async throws {
        guard let directory else {
            memory[id] = entry
            return
        }
        let sealed = try JSONEncoder().encode(try await encryptor.encryptData(try JSONEncoder().encode(entry)))
        try sealed.write(to: file(directory, id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The summaries of every chat, read from the files once.
    private func loadSummaries() async throws -> [String: ThreadSummary] {
        if let summaries { return summaries }
        var listed: [String: ThreadSummary] = [:]
        if let directory {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == Self.threadExtension {
                let id = url.deletingPathExtension().lastPathComponent
                do {
                    if let thread = try await entry(id).flatMap({ StoredThread(data: $0.thread) }) { listed[thread.id] = thread.summary }
                } catch {
                    Self.logger.error("Failed to read a chat kept on this device: \(error, privacy: .public)")
                }
            }
        } else {
            for (id, entry) in memory {
                if let thread = StoredThread(data: entry.thread) { listed[id] = thread.summary }
            }
        }
        summaries = listed
        return listed
    }
}
