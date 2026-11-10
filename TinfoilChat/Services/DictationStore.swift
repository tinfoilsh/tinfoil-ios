import Foundation
import OSLog

/// The dictation an account keeps on this device until its text reaches the
/// composer: each recording until it is transcribed, then its text. Each is
/// kept in one file sealed under the device's key, which never leaves it.
actor DictationStore {
    /// A recording of a dictation in a chat, and its text once transcribed.
    struct Segment: Codable, Equatable, Sendable {
        let chatId: String
        let dictationId: String
        let index: Int
        let startedAt: Date
        var text: String?

        var id: String { "\(dictationId)_\(index)" }
    }

    /// A segment as its file keeps it, with its recording until it is
    /// transcribed.
    private struct Entry: Codable {
        var segment: Segment
        var audio: Data?
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Dictation")
    private static let entryExtension = "dictation"
    /// Earlier versions kept each segment unsealed: its record, and its
    /// recording beside it.
    private static let plainRecordExtension = "json"

    let directory: URL
    private let encryptor: ChatEncryptor

    init(directory: URL, encryptor: ChatEncryptor = DeviceEncryptionService.shared) {
        self.directory = directory
        self.encryptor = encryptor
    }

    init(userId: String) throws {
        directory = try DictationStore.directory(userId: userId, create: true)
        encryptor = DeviceEncryptionService.shared
    }

    static func directory(userId: String, create: Bool) throws -> URL {
        let safe = userId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let url = try DeviceDataDirectory.url(create: create)
            .appendingPathComponent("dictation", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        return url
    }

    /// Forgets the dictation the account keeps, as when it signs out.
    static func wipe(userId: String) {
        if let directory = try? directory(userId: userId, create: false) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Keeps a recording until it is transcribed.
    func save(_ segment: Segment, audio: Data) async throws {
        try await write(Entry(segment: segment, audio: audio))
    }

    /// Keeps a recording's text in its place until it reaches the composer.
    func save(transcribed segment: Segment) async throws {
        try await write(Entry(segment: segment, audio: nil))
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: entryURL(id))
    }

    /// The recordings kept, with the audio of those not yet transcribed. A
    /// file that cannot be opened yet, as while the device is locked, stays
    /// for a later load; one that never will, as once the device's key is
    /// gone, is removed.
    func load() async -> [(segment: Segment, audio: Data?)] {
        await sealPlainFiles()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var kept: [(segment: Segment, audio: Data?)] = []
        for url in files where url.pathExtension == Self.entryExtension {
            guard let sealed = try? Data(contentsOf: url) else { continue }
            do {
                let envelope = try JSONDecoder().decode(EncryptedData.self, from: sealed)
                let entry = try JSONDecoder().decode(Entry.self, from: try await encryptor.decryptData(envelope))
                kept.append((entry.segment, entry.audio))
            } catch is KeychainError {
                continue
            } catch {
                Self.logger.warning("Removed dictation that can no longer be opened: \(error, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        return kept
    }

    /// Writes nothing once the account's directory was wiped.
    private func write(_ entry: Entry) async throws {
        let sealed = try JSONEncoder().encode(try await encryptor.encryptData(try JSONEncoder().encode(entry)))
        try sealed.write(to: entryURL(entry.segment.id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Seals what an earlier version kept unsealed, then removes it. A
    /// record whose recording was never written is forgotten, as is a
    /// recording no record names; one that cannot be read or sealed yet
    /// stays for a later load.
    private func sealPlainFiles() async {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == Self.plainRecordExtension {
            guard let data = try? Data(contentsOf: url),
                  let segment = try? JSONDecoder().decode(Segment.self, from: data) else { continue }
            let recording = plainAudioURL(segment.id)
            var audio: Data?
            if segment.text == nil, FileManager.default.fileExists(atPath: recording.path) {
                guard let read = try? Data(contentsOf: recording) else { continue }
                audio = read
            }
            if segment.text != nil || audio != nil {
                guard (try? await write(Entry(segment: segment, audio: audio))) != nil else { continue }
            }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: recording)
        }
        for url in files where url.pathExtension == Constants.Audio.recordingFileExtension
            && !FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension(Self.plainRecordExtension).path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func entryURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(Self.entryExtension)
    }

    private func plainAudioURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(Constants.Audio.recordingFileExtension)
    }
}
