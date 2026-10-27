import Foundation
import OSLog

/// The chats the previous client kept on this device, which the chat
/// service converts to its record once. They were encrypted under the
/// device's key in files under the account's chat directory, beside a cache
/// of the account's cloud chats that the chat service now lists itself.
enum LegacyDeviceChats {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")
    /// Chats converted per request.
    private static let batchSize = 20
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
    /// them where this client keeps device chats. A chat already stored is
    /// left as it is. The old files go once every chat is stored; the cloud
    /// cache goes with them.
    static func upgrade(userId: String, account: HarnessAccount, into store: LocalThreadStore) async {
        guard let directory = directory(userId: userId) else { return }
        let local = directory.appendingPathComponent("local", isDirectory: true)
        var files = ((try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == chatExtension && !bookkeeping.contains($0.deletingPathExtension().lastPathComponent) && !$0.lastPathComponent.hasSuffix(".sync.enc") }
        var failed = false
        while !files.isEmpty {
            let batch = Array(files.prefix(batchSize))
            files.removeFirst(batch.count)
            var records: [RawJSON] = []
            for file in batch {
                do {
                    if let record = try await read(file) { records.append(record) }
                } catch {
                    failed = true
                    logger.error("Failed to read a chat the previous client kept: \(error, privacy: .public)")
                }
            }
            guard !records.isEmpty else { continue }
            do {
                let upgraded: Upgraded = try await account.post(.upgrade, UpgradeRequest(threads: records), keyless: true)
                for raw in upgraded.threads {
                    guard let thread = StoredThread(data: raw.data) else {
                        failed = true
                        logger.error("The chat service returned a converted chat this client cannot read")
                        continue
                    }
                    _ = try await store.add(thread, originals: [:])
                }
            } catch {
                failed = true
                logger.error("Failed to upgrade chats the previous client kept: \(error, privacy: .public)")
            }
        }
        if !failed { try? FileManager.default.removeItem(at: directory) }
    }

    /// Removes everything the previous client kept for the account.
    static func wipe(userId: String) {
        guard let directory = directory(userId: userId) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A chat as the previous client wrote it, with its dates as the chat
    /// service reads them.
    private static func read(_ file: URL) async throws -> RawJSON? {
        let sealed = try Data(contentsOf: file)
        let envelope = try JSONDecoder().decode(EncryptedData.self, from: sealed)
        let data = try await DeviceEncryptionService.shared.decryptData(envelope)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] is String else { return nil }
        for member in dateMembers {
            if let seconds = object[member] as? Double {
                object[member] = StoredThread.timestamp(Date(timeIntervalSinceReferenceDate: seconds))
            }
        }
        return RawJSON(try JSONSerialization.data(withJSONObject: object))
    }
}
