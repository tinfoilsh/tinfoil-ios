import Foundation
import OSLog

/// The chats the previous client kept on this device, which the chat
/// service converts to its record once. They were encrypted under the
/// device's key in files under the account's chat directory, beside a cache
/// of the account's cloud chats that the chat service now lists itself.
enum LegacyDeviceChats {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")
    private static let chatExtension = "enc"
    /// The files of the previous client's directory that are not chats.
    private static let bookkeeping: Set<String> = ["index", "delete-intents", "remote-delete-tombstones", "remote-delete-tombstones.corrupt"]
    /// The members the previous client wrote as seconds since 2001, which
    /// the chat service reads as a time only when written as one.
    private static let dateMembers = ["createdAt", "updatedAt", "syncedAt"]

    private struct Upgraded: Decodable {
        var threads: [RawJSON]
    }

    private struct UpgradeRequest: Encodable {
        var threads: [RawJSON]
    }

    /// The previous client's chat directory for an account, if it exists.
    private static func directory(userId: String) -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let safe = userId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let url = support.appendingPathComponent("tinfoil", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Converts the account's chats kept by the previous client and stores
    /// them where this client keeps device chats, one chat per request, so a
    /// chat the chat service refuses holds back no other. A chat already
    /// stored is left as it is. Each old file goes once its chat is stored,
    /// and the directory, with the cloud cache, once every chat is.
    static func upgrade(userId: String, account: HarnessAccount, into store: LocalThreadStore) async {
        guard let directory = directory(userId: userId) else { return }
        let local = directory.appendingPathComponent("local", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == chatExtension && !bookkeeping.contains($0.deletingPathExtension().lastPathComponent) && !$0.lastPathComponent.hasSuffix(".sync.enc") }
        var kept = false
        for file in files {
            do {
                guard let row = try await read(file) else { continue }
                let upgraded: Upgraded = try await account.post(.upgrade, UpgradeRequest(threads: [RawJSON(try JSONSerialization.data(withJSONObject: row))]), keyless: true)
                guard upgraded.threads.count == 1, let thread = StoredThread(data: upgraded.threads[0].data) else {
                    throw HarnessError(HarnessErrorBody.invalidResponse, status: nil)
                }
                _ = try await store.add(thread, originals: originals(of: row, in: thread))
                try? FileManager.default.removeItem(at: file)
            } catch {
                kept = true
                logger.error("Failed to upgrade a chat the previous client kept: \(error, privacy: .public)")
            }
        }
        if !kept { try? FileManager.default.removeItem(at: directory) }
    }

    /// The images an old chat kept, as the originals of the image
    /// attachments the chat service converted them into, which keep their
    /// ids; the converted chat holds the copy models read.
    private static func originals(of row: [String: Any], in thread: StoredThread) -> Originals {
        let images = Dictionary(thread.attachments.filter { $0.kind == .image }.map { ($0.id, $0.mimeType) }, uniquingKeysWith: { first, _ in first })
        var originals: Originals = [:]
        for message in row["messages"] as? [[String: Any]] ?? [] {
            for old in message["attachments"] as? [[String: Any]] ?? [] {
                guard let id = old["id"] as? String, let mimeType = images[id], let base64 = old["base64"] as? String, !base64.isEmpty else { continue }
                originals[id] = AttachmentOriginal(base64: base64, mimeType: old["mimeType"] as? String ?? mimeType)
            }
        }
        return originals
    }

    /// Removes everything the previous client kept for the account.
    static func wipe(userId: String) {
        guard let directory = directory(userId: userId) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A chat as the previous client wrote it, with its dates as the chat
    /// service reads them.
    private static func read(_ file: URL) async throws -> [String: Any]? {
        let sealed = try Data(contentsOf: file)
        let envelope = try JSONDecoder().decode(EncryptedData.self, from: sealed)
        let data = try await DeviceEncryptionService.shared.decryptData(envelope)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] is String else { return nil }
        for member in dateMembers {
            if let seconds = object[member] as? Double {
                object[member] = StoredThread.timestamp(Date(timeIntervalSinceReferenceDate: seconds))
            }
        }
        return object
    }
}
