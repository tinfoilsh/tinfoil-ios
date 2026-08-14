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
import OSLog

actor EncryptedFileStorage {
    enum SaveError: Error {
        case remotelyDeleted
        case invalidSyncVersion
    }

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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat",
        category: "EncryptedFileStorage"
    )
    private var indexCache: [String: [ChatIndexEntry]] = [:]
    private var pendingChatIdsCache: [String: Set<String>] = [:]
    private var deleteIntentsCache: [String: [PendingChatDelete]] = [:]
    private var remoteDeleteTombstonesCache: [String: [String: Bool]] = [:]
    private var remoteDeleteRecoveryRequiredUserIds: Set<String> = []
    private var contentIntegrityCheckedUserIds: Set<String> = []
    private var contentRepairIds: [String: Set<String>] = [:]

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

    private func deleteIntentsFilePath(userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("delete-intents.enc")
    }

    private func remoteDeleteTombstonesFilePath(userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("remote-delete-tombstones.enc")
    }

    private func quarantinedRemoteDeleteTombstonesFilePath(userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("remote-delete-tombstones.corrupt.enc")
    }

    private func syncMetadataPath(chatId: String, userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("\(sanitizePathComponent(chatId)).sync.enc")
    }

    private func legacySyncMetadataPath(chatId: String, userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("\(sanitizePathComponent(chatId)).sync.json")
    }

    private func hasChatContentFile(chatId: String, userId: String) throws -> Bool {
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        return fileManager.fileExists(atPath: encPath.path)
            || fileManager.fileExists(atPath: rawPath.path)
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
        if let cached = indexCache[userId] {
            if !contentIntegrityCheckedUserIds.contains(userId) {
                try detectMissingChatContent(in: cached, userId: userId)
            }
            return cached
        }
        let indexPath = try indexFilePath(userId: userId)

        guard fileManager.fileExists(atPath: indexPath.path) else {
            return try await rebuildIndex(userId: userId)
        }

        let entries: [ChatIndexEntry]
        do {
            let fileData = try Data(contentsOf: indexPath)
            let encrypted = try decoder.decode(EncryptedData.self, from: fileData)
            let decryptedData = try await encryptor.decryptData(encrypted)
            entries = try decoder.decode([ChatIndexEntry].self, from: decryptedData)
        } catch {
            return try await rebuildIndex(userId: userId)
        }
        updateIndexCaches(entries, userId: userId)
        try detectMissingChatContent(in: entries, userId: userId)
        return entries
    }

    func saveIndex(_ entries: [ChatIndexEntry], userId: String) async throws {
        let indexPath = try indexFilePath(userId: userId)
        let jsonData = try encoder.encode(entries)
        let encrypted = try await encryptor.encryptData(jsonData)
        let fileData = try encoder.encode(encrypted)
        try fileData.write(to: indexPath, options: [.atomic, .completeFileProtection])
        updateIndexCaches(entries, userId: userId)
    }

    func pendingChatIds(userId: String) async throws -> [String] {
        _ = try await loadIndex(userId: userId)
        return Array(pendingChatIdsCache[userId] ?? [])
    }

    func pendingChatCount(userId: String) async throws -> Int {
        _ = try await loadIndex(userId: userId)
        return pendingChatIdsCache[userId]?.count ?? 0
    }

    private func updateIndexCaches(_ entries: [ChatIndexEntry], userId: String) {
        indexCache[userId] = entries
        pendingChatIdsCache[userId] = Set(entries.compactMap { entry in
            entry.needsCloudUpload ? entry.id : nil
        })
    }

    private func detectMissingChatContent(
        in entries: [ChatIndexEntry],
        userId: String
    ) throws {
        var availableIds: Set<String> = []
        for entry in entries {
            if try hasChatContentFile(chatId: entry.id, userId: userId) {
                availableIds.insert(entry.id)
            }
        }
        let missingIds = ChatContentIntegrity.missingIds(
            indexIds: entries.map(\.id)
        ) { availableIds.contains($0) }
        contentRepairIds[userId] = missingIds
        contentIntegrityCheckedUserIds.insert(userId)
    }

    func needsContentRepair(userId: String) async throws -> Bool {
        _ = try await loadIndex(userId: userId)
        return contentRepairIds[userId]?.isEmpty == false
    }

    func completeContentRepairIfResolved(
        userId: String,
        ignoring ignoredIds: Set<String>
    ) async throws -> Bool {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let indexedIds = Set(try await loadIndex(userId: userId).map(\.id))
        var unresolvedIds: Set<String> = []
        let repairCandidates = ChatContentIntegrity.repairCandidates(
            repairIds: contentRepairIds[userId] ?? [],
            indexedIds: indexedIds,
            ignoredIds: ignoredIds
        )
        for chatId in repairCandidates {
            if try !hasChatContentFile(chatId: chatId, userId: userId) {
                unresolvedIds.insert(chatId)
            }
        }
        contentRepairIds[userId] = unresolvedIds
        return unresolvedIds.isEmpty
    }

    // MARK: - Chat Operations

    func saveChat(_ chat: Chat, userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        let prepared = try await prepareLocalChatForSave(chat, userId: userId)
        try await performSaveChat(prepared, userId: userId)
    }

    private func prepareLocalChatForSave(_ chat: Chat, userId: String) async throws -> Chat {
        guard subdirectory == nil, chat.locallyModified else { return chat }
        let encPath = try chatFilePath(chatId: chat.id, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chat.id, userId: userId, isCorrupted: true)
        let hasEncryptedFile = fileManager.fileExists(atPath: encPath.path)
        var existing: Chat?
        if hasEncryptedFile || fileManager.fileExists(atPath: rawPath.path) {
            if var loaded = try await loadChatFromFile(
                hasEncryptedFile ? encPath : rawPath,
                isRaw: !hasEncryptedFile
            ) {
                await overlaySyncSidecar(&loaded, userId: userId)
                existing = loaded
            }
        }
        EditClockStore.observe(existing?.clock)
        EditClockStore.observe(chat.clock)
        var prepared = chat
        if let existing, existing.syncVersion > prepared.syncVersion {
            prepared.syncVersion = existing.syncVersion
            prepared.syncedAt = existing.syncedAt
        }
        let isContentMutation = existing?.updatedAt != chat.updatedAt
        if !isContentMutation, let existing,
           (prepared.clock ?? 0) <= (existing.clock ?? 0),
           existing.writer?.isEmpty == false {
            prepared.clock = existing.clock
            prepared.writer = existing.writer
            prepared.clockVersion = existing.clockVersion
        }
        if !isContentMutation,
           prepared.clock != nil,
           prepared.writer?.isEmpty == false {
            return prepared
        }
        let nextSyncVersion = ChatEditClockPolicy.nextSyncVersion(after: chat.syncVersion)
        let carriesNewClock = chat.clockVersion == nextSyncVersion
            && chat.clock.map { $0 > (existing?.clock ?? 0) } == true
            && chat.writer?.isEmpty == false
        if !carriesNewClock {
            let clock = try EditClockStore.nextClock(
                observedMax: max(existing?.clock ?? 0, chat.clock ?? 0)
            )
            prepared.clock = clock.v
            prepared.writer = clock.w
        }
        guard let preparedClockVersion = ChatEditClockPolicy.nextSyncVersion(
            after: prepared.syncVersion
        ) else {
            throw SaveError.invalidSyncVersion
        }
        prepared.clockVersion = preparedClockVersion
        return prepared
    }

    func applyRemoteChatIfFresh(
        _ chat: Chat,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool = false
    ) async throws -> Bool {
        try await applyRemoteChatIfFreshResult(
            chat,
            userId: userId,
            expectedLocalUpdatedAt: expectedLocalUpdatedAt,
            allowLocallyModified: allowLocallyModified
        ) == .applied
    }

    func applyRemoteChatIfFreshResult(
        _ chat: Chat,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool = false,
        allowRemoteDeleteReplacement: Bool = false
    ) async throws -> RevisionApplyResult {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let entries = (try? await loadIndex(userId: userId)) ?? []
        let existing = entries.first { $0.id == chat.id }
        let decision = RevisionApplyPolicy.contentResult(
            existing: existing,
            expectedUpdatedAt: expectedLocalUpdatedAt,
            allowLocallyModified: allowLocallyModified
        )
        guard decision == .applied else {
            return decision
        }
        EditClockStore.observe(chat.clock)
        try await performSaveChat(
            chat,
            userId: userId,
            allowRemoteDeleteReplacement: allowRemoteDeleteReplacement
        )
        return .applied
    }

    func finalizeUploadIfFresh(
        chatId: String,
        userId: String,
        expectedUpdatedAt: Date,
        syncVersion: Int,
        uploadedClock: ChatClockState,
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
        guard let persistedClock = try await loadPersistedClockState(
            chatId: chatId,
            userId: userId
        ) else {
            return false
        }
        let editedDuringUpload = existing.updatedAt != expectedUpdatedAt
            || !ChatEditClockPolicy.matchesFrozenMutation(
                current: persistedClock,
                uploaded: uploadedClock
            )
        if !attachmentRewrites.isEmpty
            || (!editedDuringUpload && existing.projectLocallyModified == true) {
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
            var didChangeChat = false
            for messageIndex in chat.messages.indices {
                for attachmentIndex in chat.messages[messageIndex].attachments.indices {
                    let clientId = chat.messages[messageIndex].attachments[attachmentIndex].id
                    guard let rewrite = rewritesByClientId[clientId] else { continue }
                    chat.messages[messageIndex].attachments[attachmentIndex].id =
                        rewrite.serverId
                    chat.messages[messageIndex].attachments[attachmentIndex].encryptionKey =
                        rewrite.encryptionKey
                    didChangeChat = true
                }
            }
            let finalizedProjectFlag = ProjectMetadataUploadPolicy.flagAfterUpload(
                current: chat.projectLocallyModified,
                editedDuringUpload: editedDuringUpload
            )
            if chat.projectLocallyModified != finalizedProjectFlag {
                chat.projectLocallyModified = finalizedProjectFlag
                didChangeChat = true
            }
            if didChangeChat {
                try await performSaveChat(chat, userId: userId)
            }
        }
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        let hasEncryptedFile = fileManager.fileExists(atPath: encPath.path)
        guard hasEncryptedFile || fileManager.fileExists(atPath: rawPath.path),
              var currentChat = try await loadChatFromFile(
                  hasEncryptedFile ? encPath : rawPath,
                  isRaw: !hasEncryptedFile
              ) else {
            return false
        }
        await overlaySyncSidecar(&currentChat, userId: userId)
        let finalizedClock = ChatEditClockPolicy.finalizedState(
            uploaded: uploadedClock,
            current: ChatClockState(
                clock: currentChat.clock,
                writer: currentChat.writer,
                clockVersion: currentChat.clockVersion
            ),
            currentSyncVersion: currentChat.syncVersion,
            currentLocallyModified: currentChat.locallyModified,
            authoritativeSyncVersion: syncVersion,
            editedDuringUpload: editedDuringUpload
        )
        if currentChat.clock != finalizedClock.clock
            || currentChat.writer != finalizedClock.writer
            || currentChat.clockVersion != finalizedClock.clockVersion {
            currentChat.clock = finalizedClock.clock
            currentChat.writer = finalizedClock.writer
            currentChat.clockVersion = finalizedClock.clockVersion
            try await performSaveChat(currentChat, userId: userId)
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

    private func loadPersistedClockState(
        chatId: String,
        userId: String
    ) async throws -> ChatClockState? {
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        let hasEncryptedFile = fileManager.fileExists(atPath: encPath.path)
        guard hasEncryptedFile || fileManager.fileExists(atPath: rawPath.path),
              let chat = try await loadChatFromFile(
                  hasEncryptedFile ? encPath : rawPath,
                  isRaw: !hasEncryptedFile
              ) else {
            return nil
        }
        return ChatClockState(
            clock: chat.clock,
            writer: chat.writer,
            clockVersion: chat.clockVersion
        )
    }

    private func performSaveChat(
        _ chat: Chat,
        userId: String,
        allowRemoteDeleteReplacement: Bool = false
    ) async throws {
        if !allowRemoteDeleteReplacement {
            let isTombstoned = try await hasRemoteDeleteTombstoneUnlocked(
                chatId: chat.id,
                userId: userId
            )
            guard !isTombstoned else { throw SaveError.remotelyDeleted }
        }
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

    func containsPendingRecovery(
        chatId: String,
        userId: String,
        envelope: PendingRecoveryEnvelope
    ) async throws -> Bool {
        try await loadChat(chatId: chatId, userId: userId)?
            .pendingRecoveries?
            .contains(envelope) == true
    }

    func containsRecoverySnapshot(
        chatId: String,
        userId: String,
        turnId: String
    ) async throws -> Bool {
        guard let chat = try await loadChat(chatId: chatId, userId: userId) else {
            return false
        }
        let hasUserTurn = chat.messages.contains {
            $0.role == .user && $0.turnId == turnId
        }
        let hasAssistantPlaceholder = chat.messages.contains {
            $0.role == .assistant && $0.turnId == turnId && $0.content.isEmpty
        }
        return hasUserTurn && hasAssistantPlaceholder
    }

    func deleteChat(chatId: String, userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        try await performDeleteChat(chatId: chatId, userId: userId)
    }

    func removeChatForConfirmedRemoteDelete(
        chatId: String,
        userId: String,
        preserveNeverSynced: Bool
    ) async throws -> Bool {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        let entries = try await loadIndex(userId: userId)
        if let entry = entries.first(where: { $0.id == chatId }),
           entry.isLocalOnly || (preserveNeverSynced && !entry.requiresCloudDelete) {
            return false
        }
        var intents = try await loadDeleteIntents(userId: userId)
        if intents.contains(where: { $0.chatId == chatId }) {
            intents.removeAll { $0.chatId == chatId }
            try await saveDeleteIntents(intents, userId: userId)
        }

        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        for path in [encPath, rawPath] where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
        try removeSyncSidecarsStrict(chatId: chatId, userId: userId)

        var updatedEntries = entries
        updatedEntries.removeAll { $0.id == chatId }
        if updatedEntries != entries {
            try await saveIndex(updatedEntries, userId: userId)
        }
        contentRepairIds[userId]?.remove(chatId)

        let contentIsAbsent = try !hasChatContentFile(chatId: chatId, userId: userId)
        let sidecarPath = try syncMetadataPath(chatId: chatId, userId: userId)
        let legacySidecarPath = try legacySyncMetadataPath(chatId: chatId, userId: userId)
        return RemoteDeleteTombstonePolicy.canClearAfterLocalCleanup(
            contentExists: !contentIsAbsent,
            sidecarExists: fileManager.fileExists(atPath: sidecarPath.path)
                || fileManager.fileExists(atPath: legacySidecarPath.path),
            removalFailed: false
        )
    }

    func stageCloudDelete(
        chatId: String,
        userId: String,
        idempotencyKey: String,
        mayHaveInFlightUpload: Bool
    ) async throws -> PendingChatDelete? {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let entries = try await loadIndex(userId: userId)
        guard DeleteIntentPlanner.shouldStage(
            entry: entries.first(where: { $0.id == chatId }),
            mayHaveInFlightUpload: mayHaveInFlightUpload
        ) else {
            return nil
        }
        var intents = try await loadDeleteIntents(userId: userId)
        let intent = DeleteIntentPlanner.intent(
            for: chatId,
            existing: intents,
            newIdempotencyKey: idempotencyKey
        )
        if !intents.contains(intent) {
            intents.append(intent)
            try await saveDeleteIntents(intents, userId: userId)
        }
        if entries.contains(where: { $0.id == chatId }) {
            try await performDeleteChat(chatId: chatId, userId: userId)
        }
        return intent
    }

    func applyRevisionMetadata(
        chatId: String,
        userId: String,
        projectId: String?,
        syncVersion: Int,
        allowRemoteDeleteReplacement: Bool = false
    ) async throws -> RevisionApplyResult {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        let entries = try await loadIndex(userId: userId)
        guard let entry = entries.first(where: { $0.id == chatId }), !entry.isLocalOnly else {
            return .refused
        }
        guard allowRemoteDeleteReplacement
            || (!entry.locallyModified && entry.projectLocallyModified != true) else {
            return .locallyModified
        }
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        let hasEncryptedFile = fileManager.fileExists(atPath: encPath.path)
        guard hasEncryptedFile || fileManager.fileExists(atPath: rawPath.path) else {
            return .refused
        }
        guard var chat = try await loadChatFromFile(
            hasEncryptedFile ? encPath : rawPath,
            isRaw: !hasEncryptedFile
        ) else {
            return .refused
        }
        await overlaySyncSidecar(&chat, userId: userId)
        let currentEntries = try await loadIndex(userId: userId)
        guard let currentEntry = currentEntries.first(where: { $0.id == chatId }),
              !currentEntry.isLocalOnly else {
            return .refused
        }
        guard allowRemoteDeleteReplacement
            || (!currentEntry.locallyModified
                && currentEntry.projectLocallyModified != true
                && !chat.locallyModified
                && chat.projectLocallyModified != true) else {
            return .locallyModified
        }
        chat.projectId = projectId
        chat.projectLocallyModified = false
        if allowRemoteDeleteReplacement {
            chat.locallyModified = false
        }
        chat.syncVersion = syncVersion
        chat.syncedAt = chat.syncedAt ?? Date()
        try await performSaveChat(
            chat,
            userId: userId,
            allowRemoteDeleteReplacement: allowRemoteDeleteReplacement
        )
        return .applied
    }

    /// Remove index entries (and their repair bookkeeping) for chats
    /// whose content file no longer exists anywhere. Called by snapshot
    /// repair for rows that are also absent remotely: with no local file
    /// and no remote row there is nothing left to recover, and keeping
    /// the entry would hold `needsContentRepair` true and fail every
    /// reconcile. The file check re-runs under the write lock so an
    /// entry whose content just reappeared (concurrent save) survives.
    func pruneUnrecoverableIndexEntries(
        chatIds: Set<String>,
        userId: String
    ) async throws -> Int {
        guard !chatIds.isEmpty else { return 0 }
        await acquireWriteLock()
        defer { releaseWriteLock() }

        var entries = try await loadIndex(userId: userId)
        var pruned = 0
        for chatId in chatIds {
            guard try !hasChatContentFile(chatId: chatId, userId: userId) else {
                continue
            }
            // Sidecars go first, and the entry is pruned only when they
            // are gone: a leftover sidecar would overlay stale metadata
            // (a stale higher syncVersion wins the sidecarIsNewer check)
            // onto a future restore of the same chat id, silently
            // poisoning its CAS base. Keeping the repair marker and index
            // entry on failure means this cycle's reconcile still fails
            // with incompletePull, but the prune — and the sidecar
            // removal — reruns every cycle, so the stall lasts only as
            // long as the removal failure (transient in practice, e.g.
            // file protection while the device is locked). The lesser
            // evil versus permanently stale metadata.
            guard try removeSyncSidecars(chatId: chatId, userId: userId) else {
                #if DEBUG
                print("[EncryptedFileStorage] deferring prune of chat \(chatId): sync sidecar removal failed")
                #endif
                continue
            }
            contentRepairIds[userId]?.remove(chatId)
            if entries.contains(where: { $0.id == chatId }) {
                entries.removeAll { $0.id == chatId }
                pruned += 1
            }
        }
        if pruned > 0 {
            try await saveIndex(entries, userId: userId)
        }
        return pruned
    }

    func missingChatContentIds(chatIds: [String], userId: String) async throws -> Set<String> {
        await acquireWriteLock()
        defer { releaseWriteLock() }

        var missingIds = contentRepairIds[userId] ?? []
        for chatId in chatIds {
            if try !hasChatContentFile(chatId: chatId, userId: userId) {
                missingIds.insert(chatId)
            }
        }
        contentRepairIds[userId] = missingIds
        return missingIds
    }

    func removeDeleteIntent(chatId: String, userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        var intents = try await loadDeleteIntents(userId: userId)
        intents.removeAll { $0.chatId == chatId }
        try await saveDeleteIntents(intents, userId: userId)
    }

    func loadDeleteIntents(userId: String) async throws -> [PendingChatDelete] {
        if let cached = deleteIntentsCache[userId] { return cached }
        let path = try deleteIntentsFilePath(userId: userId)
        guard fileManager.fileExists(atPath: path.path) else {
            deleteIntentsCache[userId] = []
            return []
        }
        let data = try Data(contentsOf: path)
        // Mirror the index's rebuild-on-failure behavior: an unreadable
        // intents file (corrupt bytes, or sealed under a key that no
        // longer exists) must reset to empty instead of throwing on
        // every sync cycle forever. Losing intents is bounded damage —
        // the remote rows resurrect locally and can be re-deleted —
        // whereas a bricked drain blocks deletes AND uploads unbounded.
        // A missing key is the one exception: it is transient (the key
        // loads later in the session), so rethrow and keep the file.
        do {
            let encrypted = try decoder.decode(EncryptedData.self, from: data)
            let plaintext = try await encryptor.decryptData(encrypted)
            let intents = try decoder.decode([PendingChatDelete].self, from: plaintext)
            deleteIntentsCache[userId] = intents
            return intents
        } catch EncryptionError.keyNotInitialized {
            throw EncryptionError.keyNotInitialized
        } catch {
            try? fileManager.removeItem(at: path)
            deleteIntentsCache[userId] = []
            return []
        }
    }

    func persistRemoteDeleteTombstone(
        chatId: String,
        userId: String,
        preserveNeverSynced: Bool
    ) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        var tombstones = try await loadRemoteDeleteTombstones(userId: userId)
        tombstones[chatId] = preserveNeverSynced
        try await saveRemoteDeleteTombstones(tombstones, userId: userId)
    }

    func loadRemoteDeleteTombstones(userId: String) async throws -> [String: Bool] {
        if let cached = remoteDeleteTombstonesCache[userId] { return cached }
        let path = try remoteDeleteTombstonesFilePath(userId: userId)
        let quarantinePath = try quarantinedRemoteDeleteTombstonesFilePath(userId: userId)
        guard fileManager.fileExists(atPath: path.path) else {
            if fileManager.fileExists(atPath: quarantinePath.path) {
                remoteDeleteRecoveryRequiredUserIds.insert(userId)
            }
            remoteDeleteTombstonesCache[userId] = [:]
            return [:]
        }
        do {
            let data = try Data(contentsOf: path)
            let encrypted = try decoder.decode(EncryptedData.self, from: data)
            let plaintext = try await encryptor.decryptData(encrypted)
            let tombstones = try decoder.decode([String: Bool].self, from: plaintext)
            if fileManager.fileExists(atPath: quarantinePath.path) {
                remoteDeleteRecoveryRequiredUserIds.insert(userId)
            }
            remoteDeleteTombstonesCache[userId] = tombstones
            return tombstones
        } catch EncryptionError.keyNotInitialized {
            throw EncryptionError.keyNotInitialized
        } catch {
            // Keep one bounded quarantine artifact and gate every cloud chat
            // save/upload until a successful authoritative snapshot has
            // reconciled remote rows and confirmed remote absences.
            if fileManager.fileExists(atPath: quarantinePath.path) {
                try fileManager.removeItem(at: quarantinePath)
            }
            try fileManager.moveItem(at: path, to: quarantinePath)
            remoteDeleteRecoveryRequiredUserIds.insert(userId)
            remoteDeleteTombstonesCache[userId] = [:]
            logger.error("Quarantined corrupt remote-delete tombstone metadata")
            return [:]
        }
    }

    func clearRemoteDeleteTombstone(chatId: String, userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        var tombstones = try await loadRemoteDeleteTombstones(userId: userId)
        guard tombstones.removeValue(forKey: chatId) != nil else { return }
        try await saveRemoteDeleteTombstones(tombstones, userId: userId)
    }

    func hasRemoteDeleteTombstone(chatId: String, userId: String) async throws -> Bool {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        return try await hasRemoteDeleteTombstoneUnlocked(chatId: chatId, userId: userId)
    }

    private func hasRemoteDeleteTombstoneUnlocked(
        chatId: String,
        userId: String
    ) async throws -> Bool {
        let tombstones = try await loadRemoteDeleteTombstones(userId: userId)
        return remoteDeleteRecoveryRequiredUserIds.contains(userId) || tombstones[chatId] != nil
    }

    func requiresRemoteDeleteRecovery(userId: String) async throws -> Bool {
        _ = try await loadRemoteDeleteTombstones(userId: userId)
        return remoteDeleteRecoveryRequiredUserIds.contains(userId)
    }

    func completeRemoteDeleteRecovery(userId: String) async throws {
        await acquireWriteLock()
        defer { releaseWriteLock() }
        let quarantinePath = try quarantinedRemoteDeleteTombstonesFilePath(userId: userId)
        if fileManager.fileExists(atPath: quarantinePath.path) {
            try fileManager.removeItem(at: quarantinePath)
        }
        remoteDeleteRecoveryRequiredUserIds.remove(userId)
    }

    private func saveRemoteDeleteTombstones(
        _ tombstones: [String: Bool],
        userId: String
    ) async throws {
        let path = try remoteDeleteTombstonesFilePath(userId: userId)
        if tombstones.isEmpty {
            if fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
            }
        } else {
            let plaintext = try encoder.encode(tombstones)
            let encrypted = try await encryptor.encryptData(plaintext)
            try encoder.encode(encrypted).write(
                to: path,
                options: [.atomic, .completeFileProtection]
            )
        }
        remoteDeleteTombstonesCache[userId] = tombstones
    }

    private func saveDeleteIntents(
        _ intents: [PendingChatDelete],
        userId: String
    ) async throws {
        let path = try deleteIntentsFilePath(userId: userId)
        if intents.isEmpty {
            if fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
            }
        } else {
            let plaintext = try encoder.encode(intents)
            let encrypted = try await encryptor.encryptData(plaintext)
            try encoder.encode(encrypted).write(
                to: path,
                options: [.atomic, .completeFileProtection]
            )
        }
        deleteIntentsCache[userId] = intents
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

    /// Best-effort removal of the sync sidecar files. Returns false when
    /// a sidecar exists but could not be removed, so callers for whom a
    /// surviving sidecar matters (the prune path — stale metadata would
    /// overlay a future restore of the same chat id) can log it.
    @discardableResult
    private func removeSyncSidecars(chatId: String, userId: String) throws -> Bool {
        var removedAll = true
        let sidecarPath = try syncMetadataPath(chatId: chatId, userId: userId)
        if fileManager.fileExists(atPath: sidecarPath.path) {
            do {
                try fileManager.removeItem(at: sidecarPath)
            } catch {
                removedAll = false
            }
        }
        let legacySidecarPath = try legacySyncMetadataPath(chatId: chatId, userId: userId)
        if fileManager.fileExists(atPath: legacySidecarPath.path) {
            do {
                try fileManager.removeItem(at: legacySidecarPath)
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }

    private func removeSyncSidecarsStrict(chatId: String, userId: String) throws {
        let sidecarPath = try syncMetadataPath(chatId: chatId, userId: userId)
        let legacySidecarPath = try legacySyncMetadataPath(chatId: chatId, userId: userId)
        for path in [sidecarPath, legacySidecarPath]
            where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
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

        try removeSyncSidecars(chatId: chatId, userId: userId)

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
        indexCache[userId] = []
        pendingChatIdsCache[userId] = []
        deleteIntentsCache[userId] = []
        remoteDeleteTombstonesCache[userId] = [:]
        remoteDeleteRecoveryRequiredUserIds.remove(userId)
        contentIntegrityCheckedUserIds.insert(userId)
        contentRepairIds[userId] = []
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
        contentIntegrityCheckedUserIds.insert(userId)
        contentRepairIds[userId] = []
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
