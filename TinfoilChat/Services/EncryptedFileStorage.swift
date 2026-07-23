//
//  EncryptedFileStorage.swift
//  TinfoilChat
//
//  Actor-based encrypted file storage for individual chat files.
//  Replaces the single keychain blob with per-chat encrypted files
//  and a lightweight index for metadata queries.
//
//  Two static instances:
//    .local  — device key, stores under {userId}/local/
//    .cloud  — cloud key, stores under {userId}/ (backward compatible)
//    .shared — alias for .cloud (backward compat for callers)
//

import Foundation

actor EncryptedFileStorage {
    static let local = EncryptedFileStorage(
        encryptor: DeviceEncryptionService.shared,
        subdirectory: "local"
    )
    static let cloud = EncryptedFileStorage(
        encryptor: EncryptionService.shared,
        subdirectory: nil
    )
    /// Backward-compatible alias for cloud storage.
    static let shared = cloud

    private let fileManager = FileManager.default
    private let encryptor: any ChatEncryptor
    private let subdirectory: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Single-writer lock that serializes mutating operations.
    // Swift actors release isolation at each `await` suspension, so
    // two concurrent saveChat/deleteChat/updateSyncMetadata calls
    // can interleave around their async hops (encryptData,
    // loadIndex, saveIndex) and stomp on each other's index
    // updates. Public mutating methods acquire this lock before
    // any work and release it when they finish, so the
    // load-mutate-save sequence is atomic relative to other writers.
    // Pure reads (loadIndex on a healthy cache, loadAllChats) skip
    // the lock; loadChat acquires it only on its rare stale-index
    // cleanup branch.
    private var writeLockHeld = false
    private var writeLockWaiters: [CheckedContinuation<Void, Never>] = []

    private init(encryptor: any ChatEncryptor, subdirectory: String?) {
        self.encryptor = encryptor
        self.subdirectory = subdirectory
    }

    private func acquireWriteLock() async {
        if !writeLockHeld {
            writeLockHeld = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeLockWaiters.append(continuation)
        }
    }

    private func releaseWriteLock() {
        if writeLockWaiters.isEmpty {
            writeLockHeld = false
        } else {
            let next = writeLockWaiters.removeFirst()
            next.resume()
        }
    }

    // MARK: - Directory / Path Helpers

    /// Sanitize a path component by removing path separators and parent-directory sequences
    /// to prevent path traversal attacks from server-controlled values.
    private func sanitizePathComponent(_ component: String) -> String {
        return component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    private func chatsDirectory(userId: String) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        var chatsDir = appSupport
            .appendingPathComponent("tinfoil", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(sanitizePathComponent(userId), isDirectory: true)

        if let sub = subdirectory {
            chatsDir = chatsDir.appendingPathComponent(sanitizePathComponent(sub), isDirectory: true)
        }

        if !fileManager.fileExists(atPath: chatsDir.path) {
            try fileManager.createDirectory(
                at: chatsDir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }

        return chatsDir
    }

    private func chatFilePath(chatId: String, userId: String, isCorrupted: Bool) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        let ext = isCorrupted ? "raw" : "enc"
        return dir.appendingPathComponent("\(sanitizePathComponent(chatId)).\(ext)")
    }

    private func indexFilePath(userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("index.enc")
    }

    private func syncMetadataPath(chatId: String, userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("\(sanitizePathComponent(chatId)).sync.enc")
    }

    private func legacySyncMetadataPath(chatId: String, userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("\(sanitizePathComponent(chatId)).sync.json")
    }

    private struct SyncMetadataSidecar: Codable {
        let syncVersion: Int
        let syncedAt: Date?
        let locallyModified: Bool
    }

    private func readSyncSidecar(chatId: String, userId: String) async -> SyncMetadataSidecar? {
        if let path = try? syncMetadataPath(chatId: chatId, userId: userId),
           fileManager.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path),
           let encrypted = try? decoder.decode(EncryptedData.self, from: data),
           let decrypted = try? await encryptor.decryptData(encrypted),
           let meta = try? decoder.decode(SyncMetadataSidecar.self, from: decrypted) {
            return meta
        }

        if let path = try? legacySyncMetadataPath(chatId: chatId, userId: userId),
           fileManager.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path),
           let meta = try? decoder.decode(SyncMetadataSidecar.self, from: data) {
            return meta
        }

        return nil
    }

    private func writeSyncSidecar(
        chatId: String,
        userId: String,
        _ meta: SyncMetadataSidecar
    ) async throws {
        let path = try syncMetadataPath(chatId: chatId, userId: userId)
        let data = try encoder.encode(meta)
        let encrypted = try await encryptor.encryptData(data)
        let encryptedData = try encoder.encode(encrypted)
        try encryptedData.write(to: path, options: [.atomic, .completeFileProtection])

        let legacyPath = try legacySyncMetadataPath(chatId: chatId, userId: userId)
        if fileManager.fileExists(atPath: legacyPath.path) {
            try? fileManager.removeItem(at: legacyPath)
        }
    }

    private func overlaySyncSidecar(_ chat: inout Chat, userId: String) async {
        guard let meta = await readSyncSidecar(chatId: chat.id, userId: userId) else { return }
        chat.syncVersion = meta.syncVersion
        chat.syncedAt = meta.syncedAt
        chat.locallyModified = meta.locallyModified
    }

    // MARK: - Index Operations

    func loadIndex(userId: String) async throws -> [ChatIndexEntry] {
        let indexPath = try indexFilePath(userId: userId)

        guard fileManager.fileExists(atPath: indexPath.path) else {
            return try await rebuildIndex(userId: userId)
        }

        do {
            let fileData = try Data(contentsOf: indexPath)
            let encrypted = try decoder.decode(EncryptedData.self, from: fileData)
            let decryptedData = try await encryptor.decryptData(encrypted)
            return try decoder.decode([ChatIndexEntry].self, from: decryptedData)
        } catch {
            return try await rebuildIndex(userId: userId)
        }
    }

    func saveIndex(_ entries: [ChatIndexEntry], userId: String) async throws {
        let indexPath = try indexFilePath(userId: userId)
        let jsonData = try encoder.encode(entries)
        let encrypted = try await encryptor.encryptData(jsonData)
        let fileData = try encoder.encode(encrypted)
        try fileData.write(to: indexPath, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Chat Operations

    func saveChat(_ chat: Chat, userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        try await performSaveChat(chat, userId: userId)
    }

    func applyRemoteChatIfFresh(
        _ chat: Chat,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool = false
    ) async throws -> Bool {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let entries = (try? await loadIndex(userId: userId)) ?? []
        let existing = entries.first { $0.id == chat.id }
        guard existing?.updatedAt == expectedLocalUpdatedAt else { return false }
        if existing?.locallyModified == true && !allowLocallyModified {
            return false
        }
        try await performSaveChat(chat, userId: userId)
        return true
    }

    func finalizeUploadIfFresh(
        chatId: String,
        userId: String,
        expectedUpdatedAt: Date,
        syncVersion: Int,
        attachmentRewrites: [
            (clientId: String, serverId: String, encryptionKey: String)
        ]
    ) async throws -> Bool {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let entries = (try? await loadIndex(userId: userId)) ?? []
        guard let existing = entries.first(where: { $0.id == chatId }) else {
            return false
        }
        let editedDuringUpload = existing.updatedAt != expectedUpdatedAt
        if !attachmentRewrites.isEmpty {
            let encPath = try chatFilePath(
                chatId: chatId,
                userId: userId,
                isCorrupted: false
            )
            let rawPath = try chatFilePath(
                chatId: chatId,
                userId: userId,
                isCorrupted: true
            )
            let hasEncryptedFile = fileManager.fileExists(atPath: encPath.path)
            let filePath = hasEncryptedFile ? encPath : rawPath
            guard fileManager.fileExists(atPath: filePath.path),
                  var chat = try await loadChatFromFile(
                      filePath,
                      isRaw: !hasEncryptedFile
                  ) else {
                return false
            }
            await overlaySyncSidecar(&chat, userId: userId)

            // The rewrites come from a server response, so tolerate
            // duplicate client ids instead of trapping on them.
            let rewritesByClientId = Dictionary(
                attachmentRewrites.map {
                    ($0.clientId, (serverId: $0.serverId, encryptionKey: $0.encryptionKey))
                },
                uniquingKeysWith: { first, _ in first }
            )
            var didRewriteAttachment = false
            for messageIndex in chat.messages.indices {
                for attachmentIndex in chat.messages[messageIndex].attachments.indices {
                    let clientId = chat.messages[messageIndex].attachments[attachmentIndex].id
                    guard let rewrite = rewritesByClientId[clientId] else { continue }
                    chat.messages[messageIndex].attachments[attachmentIndex].id =
                        rewrite.serverId
                    chat.messages[messageIndex].attachments[attachmentIndex].encryptionKey =
                        rewrite.encryptionKey
                    didRewriteAttachment = true
                }
            }
            if didRewriteAttachment {
                try await performSaveChat(chat, userId: userId)
            }
        }
        try await performUpdateSyncMetadata(
            chatId: chatId,
            userId: userId,
            syncVersion: syncVersion,
            syncedAt: editedDuringUpload ? (existing.syncedAt ?? Date()) : Date(),
            locallyModified: editedDuringUpload
        )
        return !editedDuringUpload
    }

    private func performSaveChat(_ chat: Chat, userId: String) async throws {
        let isCorrupted = chat.decryptionFailed || chat.dataCorrupted

        let data = try encoder.encode(chat)

        if isCorrupted {
            // Write as plain JSON so the next sync can replace the
            // placeholder with the enclave-unsealed copy.
            let filePath = try chatFilePath(chatId: chat.id, userId: userId, isCorrupted: true)
            try data.write(to: filePath, options: [.atomic, .completeFileProtection])

            // Remove any stale .enc file for this chat
            let encPath = try chatFilePath(chatId: chat.id, userId: userId, isCorrupted: false)
            if fileManager.fileExists(atPath: encPath.path) {
                try? fileManager.removeItem(at: encPath)
            }
        } else {
            let encrypted = try await encryptor.encryptData(data)
            let encryptedData = try encoder.encode(encrypted)
            let filePath = try chatFilePath(chatId: chat.id, userId: userId, isCorrupted: false)
            try encryptedData.write(to: filePath, options: [.atomic, .completeFileProtection])

            // Remove any stale .raw file for this chat
            let rawPath = try chatFilePath(chatId: chat.id, userId: userId, isCorrupted: true)
            if fileManager.fileExists(atPath: rawPath.path) {
                try? fileManager.removeItem(at: rawPath)
            }
        }

        // The sidecar is the source of truth for sync metadata
        // (overlaySyncSidecar reapplies it on every load), so the
        // embedded fields on the chat object can drift unless saveChat
        // promotes them. Advance the sidecar only when the caller's
        // snapshot is at least as fresh as what's already on disk,
        // otherwise a load-modify-save that overlapped a concurrent
        // updateSyncMetadata would silently regress the version.
        let existingSidecar = await readSyncSidecar(chatId: chat.id, userId: userId)
        let sidecarIsNewer = existingSidecar.map { chat.syncVersion < $0.syncVersion } ?? false
        if !sidecarIsNewer {
            try await writeSyncSidecar(
                chatId: chat.id,
                userId: userId,
                SyncMetadataSidecar(
                    syncVersion: chat.syncVersion,
                    syncedAt: chat.syncedAt,
                    locallyModified: chat.locallyModified
                )
            )
        }

        // Load the index after the file write to minimize the reentrancy window
        // between this read and the subsequent save (the await on encryptData above
        // is a suspension point where other actor methods could interleave).
        var entries = (try? await loadIndex(userId: userId)) ?? []
        var newEntry = ChatIndexEntry(from: chat)
        if sidecarIsNewer, let existingSidecar {
            // The index must stay in step with the preserved sidecar;
            // stamping the caller's stale snapshot here would regress
            // the synced/unsynced decisions made off the index.
            newEntry.syncVersion = existingSidecar.syncVersion
            newEntry.syncedAt = existingSidecar.syncedAt
            newEntry.locallyModified = existingSidecar.locallyModified
        }
        if let idx = entries.firstIndex(where: { $0.id == chat.id }) {
            entries[idx] = newEntry
        } else {
            entries.append(newEntry)
        }
        try await saveIndex(entries, userId: userId)
    }

    func loadChat(chatId: String, userId: String) async throws -> Chat? {
        // Try .enc file first
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        if fileManager.fileExists(atPath: encPath.path) {
            if var chat = try await loadChatFromFile(encPath, isRaw: false) {
                await overlaySyncSidecar(&chat, userId: userId)
                return chat
            }
            return nil
        }

        // Try .raw file
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        if fileManager.fileExists(atPath: rawPath.path) {
            if var chat = try await loadChatFromFile(rawPath, isRaw: true) {
                await overlaySyncSidecar(&chat, userId: userId)
                return chat
            }
            return nil
        }

        // Neither file exists — clean up any stale index entry.
        // This is a write, so it must hold the write lock to avoid
        // racing a concurrent saveChat that's mid-flight under the
        // same chatId.
        await acquireWriteLock()
        defer { releaseWriteLock() }

        // Re-check under the lock: a concurrent saveChat may have
        // created the file between the existence check above and
        // the lock acquisition. If so, load it normally instead of
        // erroneously deleting its fresh index entry.
        if fileManager.fileExists(atPath: encPath.path) {
            if var chat = try await loadChatFromFile(encPath, isRaw: false) {
                await overlaySyncSidecar(&chat, userId: userId)
                return chat
            }
            return nil
        }
        if fileManager.fileExists(atPath: rawPath.path) {
            if var chat = try await loadChatFromFile(rawPath, isRaw: true) {
                await overlaySyncSidecar(&chat, userId: userId)
                return chat
            }
            return nil
        }

        var entries = (try? await loadIndex(userId: userId)) ?? []
        if entries.contains(where: { $0.id == chatId }) {
            entries.removeAll { $0.id == chatId }
            try? await saveIndex(entries, userId: userId)
        }

        return nil
    }

    func deleteChat(chatId: String, userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        try await performDeleteChat(chatId: chatId, userId: userId)
    }

    /// Re-read a chat and delete it in one critical section. Holding the
    /// write lock across both the load and the delete means a concurrent
    /// saveChat cannot replace the file between the eviction check and
    /// the removal, so a fresh write is never deleted off a stale read.
    /// `shouldEvict` judges a successfully loaded chat; load errors the
    /// caller classifies as evictable delete the file, all others are
    /// rethrown. Returns true when the chat was deleted.
    func deleteChatIfEvictable(
        chatId: String,
        userId: String,
        shouldEvict: @Sendable (Chat) -> Bool,
        shouldEvictOnLoadError: @Sendable (Error) -> Bool
    ) async throws -> Bool {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        let hasEnc = fileManager.fileExists(atPath: encPath.path)
        guard hasEnc || fileManager.fileExists(atPath: rawPath.path) else {
            return false
        }

        let loaded: Chat?
        do {
            loaded = try await loadChatFromFile(hasEnc ? encPath : rawPath, isRaw: !hasEnc)
        } catch {
            guard shouldEvictOnLoadError(error) else { throw error }
            try await performDeleteChat(chatId: chatId, userId: userId)
            return true
        }
        guard var chat = loaded else { return false }
        await overlaySyncSidecar(&chat, userId: userId)
        guard shouldEvict(chat) else { return false }
        try await performDeleteChat(chatId: chatId, userId: userId)
        return true
    }

    private func performDeleteChat(chatId: String, userId: String) async throws {
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        if fileManager.fileExists(atPath: encPath.path) {
            try fileManager.removeItem(at: encPath)
        }

        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        if fileManager.fileExists(atPath: rawPath.path) {
            try fileManager.removeItem(at: rawPath)
        }

        let sidecarPath = try syncMetadataPath(chatId: chatId, userId: userId)
        if fileManager.fileExists(atPath: sidecarPath.path) {
            try? fileManager.removeItem(at: sidecarPath)
        }
        let legacySidecarPath = try legacySyncMetadataPath(chatId: chatId, userId: userId)
        if fileManager.fileExists(atPath: legacySidecarPath.path) {
            try? fileManager.removeItem(at: legacySidecarPath)
        }

        var entries = (try? await loadIndex(userId: userId)) ?? []
        entries.removeAll { $0.id == chatId }
        try await saveIndex(entries, userId: userId)
    }

    func deleteAllChats(userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let dir = try chatsDirectory(userId: userId)
        guard fileManager.fileExists(atPath: dir.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true { continue }
            try fileManager.removeItem(at: item)
        }
    }

    /// Persist sync metadata for a chat without touching its encrypted
    /// content file. The sidecar is the source of truth; loadChat
    /// overlays it onto the chat on read, so concurrent saveChat calls
    /// can never clobber an in-flight sync metadata update.
    func updateSyncMetadata(
        chatId: String,
        userId: String,
        syncVersion: Int,
        syncedAt: Date,
        locallyModified: Bool
    ) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        try await performUpdateSyncMetadata(
            chatId: chatId,
            userId: userId,
            syncVersion: syncVersion,
            syncedAt: syncedAt,
            locallyModified: locallyModified
        )
    }

    private func performUpdateSyncMetadata(
        chatId: String,
        userId: String,
        syncVersion: Int,
        syncedAt: Date,
        locallyModified: Bool
    ) async throws {
        try await writeSyncSidecar(
            chatId: chatId,
            userId: userId,
            SyncMetadataSidecar(
                syncVersion: syncVersion,
                syncedAt: syncedAt,
                locallyModified: locallyModified
            )
        )

        var entries = (try? await loadIndex(userId: userId)) ?? []
        if let idx = entries.firstIndex(where: { $0.id == chatId }) {
            entries[idx].syncVersion = syncVersion
            entries[idx].syncedAt = syncedAt
            entries[idx].locallyModified = locallyModified
            try await saveIndex(entries, userId: userId)
        }
    }

    // MARK: - Bulk Operations

    func loadChats(chatIds: [String], userId: String) async throws -> [Chat] {
        var chats: [Chat] = []
        for chatId in chatIds {
            if let chat = try await loadChat(chatId: chatId, userId: userId) {
                chats.append(chat)
            }
        }
        return chats
    }

    func loadAllChats(userId: String) async throws -> [Chat] {
        let entries = try await loadIndex(userId: userId)
        return try await loadChats(chatIds: entries.map(\.id), userId: userId)
    }

    func loadChatsWithPendingRecoveries(userId: String) async throws -> [Chat] {
        let entries = try await loadIndex(userId: userId)
        let chatIds = entries.compactMap {
            $0.hasPendingRecoveries == true ? $0.id : nil
        }
        return try await loadChats(chatIds: chatIds, userId: userId)
    }

    // MARK: - Error Recovery

    func rebuildIndex(userId: String) async throws -> [ChatIndexEntry] {
        let dir = try chatsDirectory(userId: userId)
        let contents = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []

        var entries: [ChatIndexEntry] = []

        for fileURL in contents {
            let ext = fileURL.pathExtension
            guard ext == "enc" || ext == "raw" else { continue }

            let chatId = fileURL.deletingPathExtension().lastPathComponent
            guard chatId != "index" else { continue }

            if var chat = try? await loadChatFromFile(fileURL, isRaw: ext == "raw") {
                await overlaySyncSidecar(&chat, userId: userId)
                entries.append(ChatIndexEntry(from: chat))
            }
        }

        try await saveIndex(entries, userId: userId)
        return entries
    }

    // MARK: - Private Helpers

    private func loadChatFromFile(_ fileURL: URL, isRaw: Bool) async throws -> Chat? {
        let data = try Data(contentsOf: fileURL)

        if isRaw {
            return try decoder.decode(Chat.self, from: data)
        } else {
            let encrypted = try decoder.decode(EncryptedData.self, from: data)
            let decryptedData = try await encryptor.decryptData(encrypted)
            return try decoder.decode(Chat.self, from: decryptedData)
        }
    }
}
