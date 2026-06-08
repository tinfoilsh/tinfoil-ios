//
//  CloudSyncService.swift
//  TinfoilChat
//
//  Main service for orchestrating cloud synchronization
//

import Foundation
import Combine
import ClerkKit

// MARK: - Helper Functions

/// Create properly configured ISO8601DateFormatter that handles JavaScript's toISOString() format
private func createISO8601Formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

/// Parse ISO date string with fallback for different formats
private func parseISODate(_ dateString: String) -> Date? {
    // Try with fractional seconds first (JavaScript's toISOString() format)
    let formatterWithFraction = ISO8601DateFormatter()
    formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatterWithFraction.date(from: dateString) {
        return date
    }
    
    // Try without fractional seconds
    let formatterNoFraction = ISO8601DateFormatter()
    formatterNoFraction.formatOptions = [.withInternetDateTime]
    if let date = formatterNoFraction.date(from: dateString) {
        return date
    }
    
    return nil
}

/// Coalesces rapid upload requests per chat into single uploads with exponential backoff retry.
/// Uses a dirty-flag + worker-loop pattern to batch rapid successive writes.
private actor UploadCoalescer {
    private struct ChatUploadState {
        var dirty: Bool = false
        var workerRunning: Bool = false
        var failureCount: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var throwingWaiters: [CheckedContinuation<Void, Error>] = []
    }

    private var states: [String: ChatUploadState] = [:]
    private let uploadFn: @Sendable (String, String) async throws -> Void

    init(uploadFn: @escaping @Sendable (String, String) async throws -> Void) {
        self.uploadFn = uploadFn
    }

    func enqueue(_ chatId: String) {
        var state = states[chatId] ?? ChatUploadState()
        state.dirty = true
        states[chatId] = state

        if !state.workerRunning {
            states[chatId]?.workerRunning = true
            Task { await runWorker(chatId) }
        }
    }

    func waitForUpload(_ chatId: String) async {
        guard let state = states[chatId], state.workerRunning || state.dirty else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            states[chatId]?.waiters.append(continuation)
        }
    }

    func enqueueAndWait(_ chatId: String) async throws {
        enqueue(chatId)

        guard let state = states[chatId], state.workerRunning || state.dirty else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            states[chatId]?.throwingWaiters.append(continuation)
        }
    }

    private func runWorker(_ chatId: String) async {
        var terminalError: Error?

        while states[chatId]?.dirty == true {
            states[chatId]?.dirty = false

            // Mint one idempotency key per logical write. All HTTP
            // retries inside uploadWithRetry replay under the same
            // key so the enclave collapses them to a single
            // committed effect, even when a previous attempt
            // already committed and we lost the response.
            let idempotencyKey = newSyncEnclaveIdempotencyKey()
            terminalError = await uploadWithRetry(chatId, idempotencyKey: idempotencyKey)
        }

        // Notify waiters and clean up in a single access
        let waiters = states[chatId]?.waiters ?? []
        for waiter in waiters {
            waiter.resume()
        }

        let throwingWaiters = states[chatId]?.throwingWaiters ?? []
        for waiter in throwingWaiters {
            if let terminalError {
                waiter.resume(throwing: terminalError)
            } else {
                waiter.resume()
            }
        }

        let failureCount = states[chatId]?.failureCount ?? 0
        if failureCount == 0 {
            states.removeValue(forKey: chatId)
        } else {
            states[chatId]?.workerRunning = false
            states[chatId]?.waiters = []
            states[chatId]?.throwingWaiters = []
        }
    }

    private func uploadWithRetry(_ chatId: String, idempotencyKey: String) async -> Error? {
        var lastError: Error?

        for attempt in 0...Constants.Sync.uploadMaxRetries {
            do {
                try await uploadFn(chatId, idempotencyKey)
                states[chatId]?.failureCount = 0
                return nil
            } catch {
                lastError = error
                let currentCount = states[chatId]?.failureCount ?? 0
                states[chatId]?.failureCount = currentCount + 1

                if attempt == Constants.Sync.uploadMaxRetries {
                    break
                }

                let delay = min(
                    Constants.Sync.uploadBaseDelaySeconds * pow(2.0, Double(attempt)),
                    Constants.Sync.uploadMaxDelaySeconds
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // If dirty was set during backoff, return early to upload fresh data
                let isDirty = states[chatId]?.dirty ?? false
                if isDirty {
                    return nil
                }
            }
        }

        return lastError
    }
}

/// Main service for managing cloud synchronization of chats
@MainActor
class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()
    
    // MARK: - Published Properties
    @Published var isSyncing = false
    @Published var syncStatus: String = ""
    @Published var lastSyncDate: Date?
    @Published var syncErrors: [String] = []
    
    // MARK: - Private Properties
    private lazy var uploadCoalescer: UploadCoalescer = {
        UploadCoalescer { [weak self] chatId, idempotencyKey in
            try await self?.doBackupChat(chatId, idempotencyKey: idempotencyKey)
        }
    }()
    private var streamingCallbacks: Set<String> = []
    private let cloudStorage = CloudStorageService.shared
    private let encryptionService = EncryptionService.shared
    private let deletedChatsTracker = DeletedChatsTracker.shared
    private let streamingTracker = StreamingTracker.shared
    // UserDefaults keys for sync status caches
    private let syncStatusKey = Constants.StorageKeys.Sync.chatStatus
    private let allChatsSyncStatusKey = Constants.StorageKeys.Sync.allChatsStatus

    private init() {}

    /// The enclave is the source of truth for write authority: the local
    /// CEK may write only when it derives the key id the enclave currently
    /// has registered, or when the remote has no key yet (the first sealed
    /// write registers it lazily). A local authorization hint is never
    /// sufficient on its own — another device may have rotated or reset the
    /// key, leaving this device's hint stale.
    private func canWriteToCloud() async -> Bool {
        let cek: Data
        do {
            cek = try EncryptionService.shared.getKeyBytesOrThrow()
        } catch {
            return false
        }

        let response: EnclaveKeyCurrentResponse
        do {
            response = try await SyncEnclaveAPI.keyCurrent()
        } catch {
            // Can't verify right now (offline / attestation / 5xx): defer the
            // write to a later sync cycle rather than risk writing under a
            // key the enclave no longer recognizes.
            return false
        }

        guard let remoteKeyId = response.keyId else {
            return true
        }

        let localKeyId: String
        do {
            localKeyId = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return false
        }

        return localKeyId == remoteKeyId
    }
    
    // MARK: - Initialization
    
    /// Initialize the sync service with auth token getter
    func initialize() async throws {
        // Initialize encryption service
        _ = try? await encryptionService.initialize()
        
        // Set up custom token getter for R2 storage that ensures Clerk is loaded
        let tokenGetter: () async -> String? = {
            do {
                // Check if Clerk has a publishable key
                guard !Clerk.shared.publishableKey.isEmpty else {
                    return nil
                }
                
                // Ensure Clerk is loaded
                if !Clerk.shared.isLoaded {
                    try await Clerk.shared.refreshClient()
                }
                
                // Get fresh token from session
                if let session = Clerk.shared.session {
                    // Try to get a fresh token first (refresh if needed)
                    if let token = try? await session.getToken() {
                        return token
                    }
                    // Fallback to last active token if refresh fails
                    if let tokenResource = session.lastActiveToken {
                        return tokenResource.jwt
                    }
                }
                
                return nil
            } catch {
                return nil
            }
        }
        
        // Set token getter for both R2 storage and ProfileSync
        await cloudStorage.setTokenGetter(tokenGetter)
        await ProfileSyncService.shared.setTokenGetter(tokenGetter)
        await ProjectStorageService.shared.setTokenGetter(tokenGetter)
        
    }
    
    // MARK: - Single Chat Backup
    
    /// Backup a single chat to the cloud, coalescing rapid successive calls
    func backupChat(_ chatId: String, ensureLatestUpload: Bool = false) async {
        // Don't attempt backup if not authenticated
        guard await cloudStorage.isAuthenticated() else {
            return
        }

        guard await canWriteToCloud() else {
            return
        }

        await uploadCoalescer.enqueue(chatId)

        if ensureLatestUpload {
            await uploadCoalescer.waitForUpload(chatId)
        }
    }
    
    private func doBackupChat(_ chatId: String, idempotencyKey: String) async throws {
        guard await canWriteToCloud() else { return }

        // Check if chat is currently streaming
        if streamingTracker.isStreaming(chatId) {
            // Check if we already have a callback registered for this chat
            if streamingCallbacks.contains(chatId) {
                return
            }
            
            
            // Mark that we have a callback registered
            streamingCallbacks.insert(chatId)
            
            // Register to sync once streaming ends
            streamingTracker.onStreamEnd(chatId) { [weak self] in
                Task { @MainActor in
                    // Remove from tracking set
                    self?.streamingCallbacks.remove(chatId)
                    
                    
                    // Re-trigger the backup after streaming ends
                    await self?.backupChat(chatId)
                }
            }
            
            return
        }
        
        // Load chat from storage
        guard let chat = await loadChatFromStorage(chatId) else {
            return // Chat might have been deleted
        }
        
        
        // Don't sync blank, empty, decryption-failure, or local-only chats.
        // Local-only chats are the user's explicit choice to keep a chat off
        // the cloud, so they must never be uploaded.
        if chat.isBlankChat || chat.messages.isEmpty || chat.decryptionFailed || chat.isLocalOnly {
            return
        }

        // Double-check streaming status right before upload
        if streamingTracker.isStreaming(chatId) {
            return
        }
        
        do {
            try await uploadAndMarkSynced(chat, idempotencyKey: idempotencyKey)
        } catch {
            try await handleUploadFailure(chatId: chatId, error: error)
        }
    }

    /// Dispatch a sync-enclave error to the matching recovery
    /// surface. Re-throws for retryable cases so the coalescer can
    /// retry under the same idempotency key; swallows for
    /// non-retryable cases after posting a notification so the
    /// chat stays locallyModified and is picked up on the next
    /// natural sync cycle without burning the retry budget.
    private func handleUploadFailure(chatId: String, error: Error) async throws {
        let decision = EnclaveErrorRecovery.decide(error)
        #if DEBUG
        print("[CloudSync] upload recovery decision chat=\(chatId) action=\(decision.action) code=\(decision.classification.code?.rawValue ?? "nil")")
        #endif
        switch decision.action {
        case .retry:
            throw error
        case .refreshCurrentKeyAndRetry:
            // Notify so a listener (e.g. PasskeyManager) refreshes
            // the canonical enclave key, then re-throw so the
            // coalescer retries under the same idempotency key.
            // The retry replays after the listener (hopefully) has
            // rotated the key; if it hasn't yet, the retry fails
            // and the chat stays locallyModified for the next sync
            // cycle.
            postSyncEvent(.tinfoilSyncKeyRefreshNeeded)
            throw error
        case .surfaceConflict:
            postSyncEvent(.tinfoilSyncConflictDetected, userInfo: ["chatId": chatId])
            await resolveConflictByPullingRemote(chatId)
        case .surfaceExistingDataUnderOtherKey:
            postSyncEvent(.tinfoilSyncExistingDataUnderOtherKey)
        case .surfaceNotFound:
            postSyncEvent(.tinfoilSyncChatNotFound, userInfo: ["chatId": chatId])
        case .triggerRecoveryWizard:
            postSyncEvent(.tinfoilSyncRecoveryNeeded)
        case .blockAllSync:
            postSyncEvent(.tinfoilSyncAttestationFailed)
        case .migrateLegacyAndRetry:
            // Re-throw so the coalescer retries the write. The legacy
            // re-seal runs out of band — on the next launch and right
            // after the key is adopted (see PasskeyManager) — both
            // gated on the key being the registered current key. If
            // that completes before retries exhaust the upload
            // succeeds; otherwise the chat waits for the next cycle.
            throw error
        case .abort(let reason):
            postSyncEvent(
                .tinfoilSyncUploadAborted,
                userInfo: ["chatId": chatId, "reason": reason.rawValue]
            )
        }
    }

    private func postSyncEvent(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// Last-write-wins conflict resolution. Pulls the remote chat
    /// fresh from the enclave and overwrites the local copy so the
    /// chat exits the stuck-row retry loop. If the pull itself
    /// fails the chat stays locallyModified and the next sync
    /// cycle retries.
    private func resolveConflictByPullingRemote(_ chatId: String) async {
        do {
            guard var downloadedChat = try await cloudStorage.downloadChat(chatId) else {
                return
            }
            if downloadedChat.modelType == nil {
                downloadedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }
            await saveChatToStorage(downloadedChat)
            await markChatAsSynced(downloadedChat.id, version: downloadedChat.syncVersion)
        } catch {
            #if DEBUG
            print("[CloudSync] resolveConflictByPullingRemote failed for \(chatId): \(error)")
            #endif
        }
    }

    // MARK: - Bulk Sync Operations
    
    /// Backup all unsynced chats
    func backupUnsyncedChats() async -> SyncResult {
        var result = SyncResult()

        guard await canWriteToCloud() else {
            return result
        }
        
        let unsyncedChats = await getUnsyncedChats()
        
        
        // Filter out blank, empty, decryption failure, and streaming chats
        var chatsToSync: [Chat] = []
        for chat in unsyncedChats {
            if !chat.isBlankChat && !chat.messages.isEmpty && !chat.decryptionFailed {
                let isStreaming = streamingTracker.isStreaming(chat.id)
                if !isStreaming {
                    chatsToSync.append(chat)
                }
            }
        }
        
        
        // Upload chats sequentially to avoid connection exhaustion
        for chat in chatsToSync {
            // Skip if chat started streaming
            if streamingTracker.isStreaming(chat.id) {
                continue
            }

            do {
                try await uploadCoalescer.enqueueAndWait(chat.id)
                result = SyncResult(
                    uploaded: result.uploaded + 1,
                    downloaded: result.downloaded,
                    errors: result.errors
                )
            } catch {
                result = SyncResult(
                    uploaded: result.uploaded,
                    downloaded: result.downloaded,
                    errors: result.errors + ["Failed to backup chat \(chat.id): \(error.localizedDescription)"]
                )
            }
        }
        
        return result
    }
    
    // MARK: - Pagination Support
    
    /// Load chats with pagination, combining local and remote sources
    func loadChatsWithPagination(
        limit: Int? = nil,
        continuationToken: String? = nil,
        loadLocal: Bool = true
    ) async -> PaginatedChatsResult {
        let pageLimit = limit ?? Constants.Pagination.chatsPerPage
        // If not authenticated, fall back to local-only pagination
        guard await cloudStorage.isAuthenticated() else {
            if loadLocal {
                return await loadLocalChatsWithPagination(
                    limit: pageLimit,
                    continuationToken: continuationToken
                )
            }
            return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
        }
        
        do {
            // Fetch remote chats with pagination
            // includeContent: true to get the encrypted data directly
            let remoteList = try await cloudStorage.listChats(
                limit: pageLimit,
                continuationToken: continuationToken,
                includeContent: true
            )
            
            // Process remote chats in parallel
            var downloadedChats: [StoredChat] = []
            let chatsToProcess = remoteList.conversations
            
            // Initialize encryption if available; continue even without a key so we can at least
            // fetch metadata and store encrypted placeholders. Decryption will be attempted per-chat.
            _ = try? await encryptionService.initialize()

            // Process chats sequentially to avoid connection exhaustion
            for remoteChat in chatsToProcess {
                // Skip recently deleted chats
                if deletedChatsTracker.isDeleted(remoteChat.id) {
                    continue
                }

                // Skip invalid chats (blank or without proper ID format)
                if !(await shouldProcessRemoteChat(remoteChat)) {
                    continue
                }

                guard let content = remoteChat.content else {
                    continue
                }

                if let decrypted = await decryptRemoteChat(remoteChat, content: content) {
                    downloadedChats.append(decrypted.chat)
                } else {
                    let placeholder = createEncryptedPlaceholder(remoteChat: remoteChat)
                    downloadedChats.append(placeholder)
                }
            }

            // Sort by latest activity (newest first), matching the server's
            // direction=desc list-status pagination.
            downloadedChats.sort { $0.updatedAt > $1.updatedAt }
            
            return PaginatedChatsResult(
                chats: downloadedChats,
                hasMore: remoteList.hasMore,
                nextToken: remoteList.nextContinuationToken
            )
            
        } catch {
            // On error, fall back to local if enabled
            if loadLocal {
                return await loadLocalChatsWithPagination(
                    limit: pageLimit,
                    continuationToken: continuationToken
                )
            }
            return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
        }
    }
    
    /// Load local chats with pagination (fallback when offline or not authenticated)
    private func loadLocalChatsWithPagination(
        limit: Int,
        continuationToken: String?
    ) async -> PaginatedChatsResult {
        let allChats = await getAllChatsFromStorage()
        
        // Sort by latest activity (newest first), matching the server's
        // direction=desc list-status pagination.
        let sortedChats = allChats.sorted { $0.updatedAt > $1.updatedAt }
        
        // Parse continuation token as offset
        let offset = Int(continuationToken ?? "0") ?? 0
        
        // Safety check for bounds
        guard offset < sortedChats.count else {
            // We've gone past the end
            return PaginatedChatsResult(
                chats: [],
                hasMore: false,
                nextToken: nil
            )
        }
        
        // Get page of chats
        let pageEnd = min(offset + limit, sortedChats.count)
        let pageChats = Array(sortedChats[offset..<pageEnd])
        
        // Convert to StoredChat format
        let storedChats = pageChats.map { StoredChat(from: $0) }
        
        // Determine if there are more pages
        let hasMore = pageEnd < sortedChats.count
        let nextToken = hasMore ? String(pageEnd) : nil
        
        return PaginatedChatsResult(
            chats: storedChats,
            hasMore: hasMore,
            nextToken: nextToken
        )
    }
    
    /// Apply server metadata dates and set a default model on a chat
    /// the enclave already unsealed for us. `content` is the StoredChat
    /// JSON returned by `/v1/sync/pull` (format-version 2).
    /// Returns `nil` on a malformed body — callers create an encrypted
    /// placeholder in that case.
    struct DecryptedChatResult {
        var chat: StoredChat
    }

    private func decryptRemoteChat(
        _ remoteChat: RemoteChat,
        content: String
    ) async -> DecryptedChatResult? {
        guard let plaintextData = content.data(using: .utf8) else { return nil }

        do {
            var decryptedChat = try JSONDecoder().decode(StoredChat.self, from: plaintextData)
            decryptedChat.formatVersion = 2
            if let remoteProjectId = remoteChat.projectId {
                decryptedChat.projectId = remoteProjectId
            }

            // Prefer the blob's createdAt over the remote metadata.
            // StoredChat falls back to `Date()` on parse failure — when
            // the blob date is within the last few seconds it's almost
            // certainly that fallback, so prefer the server timestamp.
            let blobCreatedAt = decryptedChat.createdAt
            let blobLooksLikeFallback = abs(blobCreatedAt.timeIntervalSinceNow) < Constants.Sync.createdAtFallbackThresholdSeconds
            if blobLooksLikeFallback, let createdDate = parseISODate(remoteChat.createdAt) {
                decryptedChat.createdAt = createdDate
            }
            if let updatedDate = parseISODate(remoteChat.updatedAt) {
                decryptedChat.updatedAt = updatedDate
            }
            if decryptedChat.modelType == nil {
                decryptedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }

            return DecryptedChatResult(chat: decryptedChat)
        } catch {
            return nil
        }
    }

    /// Create a placeholder for a chat the enclave declined to unseal
    /// (e.g. UNKNOWN_KEY). The ciphertext stays server-side; the local
    /// row is purely a "this chat exists but cannot be read" badge.
    private func createEncryptedPlaceholder(remoteChat: RemoteChat) -> StoredChat {
        StoredChat.encryptedPlaceholder(
            id: remoteChat.id,
            createdAt: parseISODate(remoteChat.createdAt) ?? Date(),
            updatedAt: parseISODate(remoteChat.updatedAt) ?? Date()
        )
    }
    
    /// Download a remote chat by ID, apply metadata dates, and save locally.
    /// Returns `true` if the chat was downloaded and saved, `false` on failure.
    private func downloadAndSaveRemoteChat(_ remoteChat: RemoteChat, projectId: String? = nil) async throws {
        guard var downloadedChat = try await cloudStorage.downloadChat(remoteChat.id) else {
            return
        }
        if let projectId = projectId ?? remoteChat.projectId {
            downloadedChat.projectId = projectId
        }

        // If decryption failed, don't overwrite a valid local copy.
        if downloadedChat.decryptionFailed == true {
            if let localChat = await loadChatFromStorage(remoteChat.id),
               !localChat.messages.isEmpty,
               !localChat.decryptionFailed {
                return
            }
        }

        // Prefer blob's createdAt; only fall back to server metadata when
        // the blob value looks like a decoder fallback (Date()).
        let blobCreatedAt = downloadedChat.createdAt
        let blobLooksLikeFallback = abs(blobCreatedAt.timeIntervalSinceNow) < Constants.Sync.createdAtFallbackThresholdSeconds
        if blobLooksLikeFallback, let createdDate = parseISODate(remoteChat.createdAt) {
            downloadedChat.createdAt = createdDate
        }
        if let updatedDate = parseISODate(remoteChat.updatedAt) {
            downloadedChat.updatedAt = updatedDate
        }

        if downloadedChat.modelType == nil {
            downloadedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
        }

        await saveChatToStorage(downloadedChat)
        await markChatAsSynced(downloadedChat.id, version: downloadedChat.syncVersion)
    }

    /// Sync all chats (upload local changes, download remote changes)
    func syncAllChats(deep: Bool = false) async -> SyncResult {
        guard !isSyncing else {
            return SyncResult()
        }

        isSyncing = true
        syncStatus = "Syncing..."
        defer {
            isSyncing = false
            syncStatus = ""
            lastSyncDate = Date()
        }

        let result = await doSyncAllChats(deep: deep)
        syncErrors = result.errors
        return result
    }

    private func doSyncAllChats(deep: Bool = false) async -> SyncResult {
        var result = SyncResult()

        // Delete local chats that were deleted on another device
        var deletedCount = 0
        if let cachedStatus = getCachedSyncStatus(),
           let lastUpdated = cachedStatus.lastUpdated {
            deletedCount = await deleteRemotelyDeletedChats(since: lastUpdated)
        }

        // First, backup any unsynced local changes
        let backupResult = await backupUnsyncedChats()
        result = SyncResult(
            uploaded: backupResult.uploaded,
            downloaded: 0,
            deleted: deletedCount,
            errors: backupResult.errors
        )

        // Then, get list of remote chats with content
        do {
            let localChats = await getAllChatsFromStorage()

            // Initialize encryption if available; continue even without a key so we can at least
            // fetch metadata and store encrypted placeholders. Decryption will be attempted per-chat.
            _ = try? await encryptionService.initialize()

            // Create maps for easy lookup
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })

            // A deep sync (pull-to-refresh) keeps paging through the rest of
            // the remote history so older chats that predate this device's
            // local copy are pulled down too. The periodic and launch syncs
            // stay first-page-only for bandwidth.
            var continuationToken: String? = nil
            repeat {
                let remoteList = try await cloudStorage.listChats(
                    limit: Constants.Pagination.chatsPerPage,
                    continuationToken: continuationToken,
                    includeContent: true
                )
                let remoteConversations = remoteList.conversations

                // Process remote chats sequentially to avoid connection exhaustion
            for remoteChat in remoteConversations {
                // First validate if this remote chat should be processed
                if !(await shouldProcessRemoteChat(remoteChat)) {
                    // Clean up invalid chats from cloud
                    cleanupInvalidRemoteChat(remoteChat)
                    continue
                }

                let localChat = localChatMap[remoteChat.id]

                // Process if:
                // 1. Chat doesn't exist locally
                // 2. Remote is newer (based on updatedAt > syncedAt) AND chat is not locally modified
                // 3. Chat failed decryption (to retry with new key)
                // 4. Never overwrite if chat has active stream or is locally modified
                let remoteTimestamp = parseISODate(remoteChat.updatedAt)?.timeIntervalSince1970 ?? 0

                // Skip if chat is locally modified or has active stream
                if let localChat = localChat {
                    if localChat.locallyModified || localChat.hasActiveStream {
                        continue
                    }

                    // Also check if chat is currently streaming using the tracker
                    if streamingTracker.isStreaming(localChat.id) {
                        continue
                    }
                }

                let shouldProcess = localChat == nil ||
                    (!remoteTimestamp.isNaN && remoteTimestamp > (localChat?.syncedAt?.timeIntervalSince1970 ?? 0)) ||
                    (localChat?.decryptionFailed == true)

                if shouldProcess {
                    if let content = remoteChat.content {
                        if let decrypted = await decryptRemoteChat(remoteChat, content: content) {
                            // Validate the content
                            if decrypted.chat.messages.isEmpty {
                                cleanupInvalidRemoteChat(remoteChat)
                                continue
                            }

                            await saveChatToStorage(decrypted.chat)
                            await markChatAsSynced(decrypted.chat.id, version: decrypted.chat.syncVersion)
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded + 1,
                                deleted: result.deleted,
                                errors: result.errors
                            )
                        } else {
                            // Only save a placeholder if there is no valid local copy.
                            // When a good local version exists (non-empty messages, not
                            // already failed), preserve it to avoid replacing decrypted
                            // content with an empty encrypted placeholder (e.g. after
                            // the remote was re-encrypted with a key we don't have yet).
                            let hasValidLocal = localChat.map { !$0.messages.isEmpty && !$0.decryptionFailed } ?? false
                            if !hasValidLocal {
                                let placeholder = createEncryptedPlaceholder(remoteChat: remoteChat)
                                await saveChatToStorage(placeholder)
                                result = SyncResult(
                                    uploaded: result.uploaded,
                                    downloaded: result.downloaded + 1,
                                    deleted: result.deleted,
                                    errors: result.errors
                                )
                            }
                        }
                    } else {
                        // No inline content - fetch via downloadChat (handles its own decryption)
                        do {
                            try await downloadAndSaveRemoteChat(remoteChat)
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded + 1,
                                deleted: result.deleted,
                                errors: result.errors
                            )
                        } catch {
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded,
                                deleted: result.deleted,
                                errors: result.errors + ["Failed to download chat \(remoteChat.id): \(error.localizedDescription)"]
                            )
                        }
                    }
                }
            }

                let nextToken = remoteList.nextContinuationToken?.isEmpty == false
                    ? remoteList.nextContinuationToken
                    : nil
                continuationToken = (deep && remoteList.hasMore) ? nextToken : nil
            } while continuationToken != nil

            // Refresh cached sync status so subsequent smart-syncs have up-to-date info
            await refreshSyncStatusCache()

            // Detect cross-scope moves (chats moving between projects)
            await syncCrossScope()

        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                deleted: result.deleted,
                errors: result.errors + ["Sync failed: \(error.localizedDescription)"]
            )
        }

        return result
    }

    // MARK: - Smart Sync Operations

    /// Check if sync is needed by comparing with cached status
    func checkSyncStatus() async -> SyncStatusResult {
        // Check for local unsynced changes first
        let unsyncedChats = await getUnsyncedChats()
        let hasLocalChanges = !unsyncedChats.filter { !$0.isBlankChat && !$0.messages.isEmpty }.isEmpty

        if hasLocalChanges {
            return SyncStatusResult(
                needsSync: true,
                reason: .localChanges,
                remoteCount: nil,
                remoteLastUpdated: nil
            )
        }

        // Get remote sync status
        do {
            let remoteStatus = try await cloudStorage.getChatSyncStatus()

            // Get cached status
            let cachedStatus = getCachedSyncStatus()

            // Compare with cached status
            if let cached = cachedStatus {
                if remoteStatus.count != cached.count {
                    return SyncStatusResult(
                        needsSync: true,
                        reason: .countChanged,
                        remoteCount: remoteStatus.count,
                        remoteLastUpdated: remoteStatus.lastUpdated
                    )
                }

                if let remoteUpdated = remoteStatus.lastUpdated,
                   let cachedUpdated = cached.lastUpdated,
                   remoteUpdated != cachedUpdated {
                    return SyncStatusResult(
                        needsSync: true,
                        reason: .updated,
                        remoteCount: remoteStatus.count,
                        remoteLastUpdated: remoteStatus.lastUpdated
                    )
                }

                // Detect the disk-lost-rows case after the more
                // precise remote-side signals above. The cached
                // count tracks the server, not what is actually on
                // disk — so a chat that 404s during decrypt, an
                // eviction sweep, or any other path that silently
                // drops rows can leave the watermark intact even
                // though the user can no longer see those chats.
                // When the live local count drops below the
                // snapshot we last persisted, force a full pull.
                // Older cached entries (no `localCount`) keep the
                // legacy behaviour to avoid spurious sync storms on
                // first upgrade.
                if let cachedLocal = cached.localCount {
                    let liveLocal = await safeReadLocalChatCount() ?? cachedLocal
                    if liveLocal < cachedLocal {
                        return SyncStatusResult(
                            needsSync: true,
                            reason: .countChanged,
                            remoteCount: remoteStatus.count,
                            remoteLastUpdated: remoteStatus.lastUpdated
                        )
                    }
                }

                return SyncStatusResult(
                    needsSync: false,
                    reason: .noChanges,
                    remoteCount: remoteStatus.count,
                    remoteLastUpdated: remoteStatus.lastUpdated
                )
            }

            // No cached status - need full sync
            return SyncStatusResult(
                needsSync: true,
                reason: .countChanged,
                remoteCount: remoteStatus.count,
                remoteLastUpdated: remoteStatus.lastUpdated
            )
        } catch {
            return SyncStatusResult(
                needsSync: true,
                reason: .error,
                remoteCount: nil,
                remoteLastUpdated: nil
            )
        }
    }

    /// Sync only chats that changed since last sync
    private func syncChangedChats(since: String) async -> SyncResult {
        var result = SyncResult()

        // Delete local chats that were deleted on another device
        let deletedCount = await deleteRemotelyDeletedChats(since: since)

        // Backup any unsynced local changes first (matches doSyncAllChats behavior)
        let backupResult = await backupUnsyncedChats()
        result = SyncResult(
            uploaded: backupResult.uploaded,
            downloaded: 0,
            deleted: deletedCount,
            errors: backupResult.errors
        )

        do {
            _ = try? await encryptionService.initialize()

            let localChats = await getAllChatsFromStorage()
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })

            // Paginate through all changed chats
            var hasMore = true
            var continuationToken: String? = nil

            while hasMore {
                let changedChats = try await cloudStorage.getChatsUpdatedSince(
                    since: since,
                    includeContent: true,
                    continuationToken: continuationToken
                )

                for remoteChat in changedChats.conversations {
                    if deletedChatsTracker.isDeleted(remoteChat.id) {
                        continue
                    }

                    if !(await shouldProcessRemoteChat(remoteChat)) {
                        continue
                    }

                    // Skip if chat is locally modified or has active stream
                    if let localChat = localChatMap[remoteChat.id] {
                        if localChat.locallyModified || localChat.hasActiveStream {
                            continue
                        }

                        if streamingTracker.isStreaming(localChat.id) {
                            continue
                        }
                    }

                    if let content = remoteChat.content {
                        if let decrypted = await decryptRemoteChat(remoteChat, content: content) {
                            await saveChatToStorage(decrypted.chat)
                            await markChatAsSynced(decrypted.chat.id, version: decrypted.chat.syncVersion)
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded + 1,
                                deleted: result.deleted,
                                errors: result.errors
                            )
                        } else {
                            // Only save a placeholder when no valid local copy exists.
                            let localChat = localChatMap[remoteChat.id]
                            let hasValidLocal = localChat.map { !$0.messages.isEmpty && !$0.decryptionFailed } ?? false
                            if !hasValidLocal {
                                let placeholder = createEncryptedPlaceholder(remoteChat: remoteChat)
                                await saveChatToStorage(placeholder)
                                result = SyncResult(
                                    uploaded: result.uploaded,
                                    downloaded: result.downloaded + 1,
                                    deleted: result.deleted,
                                    errors: result.errors
                                )
                            }
                        }
                    } else {
                        // No inline content - fetch via downloadChat (handles its own decryption)
                        do {
                            try await downloadAndSaveRemoteChat(remoteChat)
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded + 1,
                                deleted: result.deleted,
                                errors: result.errors
                            )
                        } catch {
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded,
                                deleted: result.deleted,
                                errors: result.errors + ["Failed to download chat \(remoteChat.id): \(error.localizedDescription)"]
                            )
                        }
                    }
                }

                let nextToken = changedChats.nextContinuationToken?.isEmpty == false ? changedChats.nextContinuationToken : nil
                hasMore = changedChats.hasMore && nextToken != nil
                continuationToken = nextToken
            }

            // Refresh cached sync status so subsequent smart-syncs have up-to-date info
            await refreshSyncStatusCache()

            // Detect cross-scope moves (chats moving between projects)
            await syncCrossScope()
        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                deleted: result.deleted,
                errors: result.errors + ["Delta sync failed: \(error.localizedDescription)"]
            )
        }

        return result
    }

    /// Smart sync - only sync if changes detected
    func smartSync() async -> SyncResult {
        guard !isSyncing else {
            return SyncResult()
        }

        guard await cloudStorage.isAuthenticated() else {
            return SyncResult()
        }

        let statusCheck = await checkSyncStatus()

        if !statusCheck.needsSync {
            // A deletion from another device can be absorbed into the status
            // cache (the count matches again) on the same tick its tombstone
            // was missed locally, after which the count gate never reopens and
            // the orphan lingers until a full reload. Re-run the tombstone
            // reconciliation here so a missed deletion self-heals on the next
            // tick. The pass is idempotent and only reports chats actually
            // removed locally, so it triggers a UI reload only when needed.
            if let cachedStatus = getCachedSyncStatus(),
               let lastUpdated = cachedStatus.lastUpdated {
                let reconciled = await deleteRemotelyDeletedChats(since: lastUpdated)
                if reconciled > 0 {
                    return SyncResult(deleted: reconciled)
                }
            }
            return SyncResult()
        }

        isSyncing = true
        syncStatus = "Syncing..."
        defer {
            isSyncing = false
            syncStatus = ""
            lastSyncDate = Date()
        }

        var result = SyncResult()

        // If only timestamp changed (not count), try delta sync
        if statusCheck.reason == .updated,
           let cachedStatus = getCachedSyncStatus(),
           let lastUpdated = cachedStatus.lastUpdated {
            let deltaResult = await syncChangedChats(since: lastUpdated)
            result = SyncResult(
                uploaded: result.uploaded + deltaResult.uploaded,
                downloaded: result.downloaded + deltaResult.downloaded,
                deleted: result.deleted + deltaResult.deleted,
                errors: result.errors + deltaResult.errors
            )

            if !deltaResult.errors.isEmpty {
                // Delta sync failed, fall back to full sync
                let fullResult = await doSyncAllChats()
                result = SyncResult(
                    uploaded: result.uploaded + fullResult.uploaded,
                    downloaded: result.downloaded + fullResult.downloaded,
                    deleted: result.deleted + fullResult.deleted,
                    errors: fullResult.errors
                )
            }
        } else {
            // Count changed, local changes, or no cached status - need full sync
            let fullResult = await doSyncAllChats()
            result = SyncResult(
                uploaded: result.uploaded + fullResult.uploaded,
                downloaded: result.downloaded + fullResult.downloaded,
                deleted: result.deleted + fullResult.deleted,
                errors: result.errors + fullResult.errors
            )
        }

        syncErrors = result.errors
        return result
    }

    func smartSync(projectId: String?) async -> SyncResult {
        guard let projectId else {
            return await smartSync()
        }
        return await smartSyncProjectChats(projectId)
    }

    func updateChatProject(_ chatId: String, projectId: String?) async throws {
        guard await canWriteToCloud() else { return }
        try await cloudStorage.updateChatProject(chatId: chatId, projectId: projectId)
    }

    func syncProjectChats(_ projectId: String) async -> SyncResult {
        guard !isSyncing else {
            return SyncResult()
        }

        guard await cloudStorage.isAuthenticated() else {
            return SyncResult()
        }

        isSyncing = true
        syncStatus = "Syncing project..."
        defer {
            isSyncing = false
            syncStatus = ""
            lastSyncDate = Date()
        }

        let result = await doSyncProjectChats(projectId)
        syncErrors = result.errors
        return result
    }

    private func smartSyncProjectChats(_ projectId: String) async -> SyncResult {
        guard !isSyncing else {
            return SyncResult()
        }

        guard await cloudStorage.isAuthenticated() else {
            return SyncResult()
        }

        let unsyncedChats = await getUnsyncedChats()
        let localProjectChanges = unsyncedChats.contains {
            $0.projectId == projectId && !$0.isBlankChat && !$0.messages.isEmpty
        }

        do {
            let remoteStatus = try await cloudStorage.getProjectChatsSyncStatus(projectId: projectId)
            let cachedStatus = getCachedProjectChatSyncStatus(projectId)

            if !localProjectChanges,
               let cachedStatus,
               remoteStatus.count == cachedStatus.count,
               remoteStatus.lastUpdated == cachedStatus.lastUpdated {
                return SyncResult()
            }

            isSyncing = true
            syncStatus = "Syncing project..."
            defer {
                isSyncing = false
                syncStatus = ""
                lastSyncDate = Date()
            }

            if !localProjectChanges,
               let cachedLastUpdated = cachedStatus?.lastUpdated,
               remoteStatus.count == cachedStatus?.count {
                let result = await syncProjectChatsChanged(projectId, since: cachedLastUpdated)
                if result.errors.isEmpty {
                    saveProjectChatSyncStatus(projectId, remoteStatus)
                    return result
                }
            }

            let result = await doSyncProjectChats(projectId)
            syncErrors = result.errors
            return result
        } catch {
            return await syncProjectChats(projectId)
        }
    }

    private func doSyncProjectChats(_ projectId: String) async -> SyncResult {
        await syncProjectChatsRemote(
            projectId: projectId,
            errorPrefix: "Project sync failed",
            applyShouldProcessFilter: true,
            fetchPage: { [cloudStorage] continuationToken in
                let page = try await cloudStorage.listProjectChats(
                    projectId: projectId,
                    includeContent: true,
                    continuationToken: continuationToken
                )
                return (page.chats, page.nextContinuationToken, page.hasMore == true)
            }
        )
    }

    private func syncProjectChatsChanged(_ projectId: String, since: String) async -> SyncResult {
        await syncProjectChatsRemote(
            projectId: projectId,
            errorPrefix: "Project delta sync failed",
            applyShouldProcessFilter: false,
            fetchPage: { [cloudStorage] continuationToken in
                let page = try await cloudStorage.getProjectChatsUpdatedSince(
                    projectId: projectId,
                    since: since,
                    continuationToken: continuationToken
                )
                return (page.chats, page.nextContinuationToken, page.hasMore == true)
            }
        )
    }

    private func syncProjectChatsRemote(
        projectId: String,
        errorPrefix: String,
        applyShouldProcessFilter: Bool,
        fetchPage: (String?) async throws -> (chats: [RemoteChat], nextToken: String?, hasMore: Bool)
    ) async -> SyncResult {
        var result = SyncResult()

        let backupResult = await backupUnsyncedProjectChats(projectId)
        result = SyncResult(
            uploaded: backupResult.uploaded,
            downloaded: 0,
            deleted: 0,
            errors: backupResult.errors
        )

        do {
            _ = try? await encryptionService.initialize()

            let localChats = await getAllChatsFromStorage()
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })
            var continuationToken: String? = nil

            repeat {
                let page = try await fetchPage(continuationToken)

                for remoteChat in page.chats {
                    if deletedChatsTracker.isDeleted(remoteChat.id) {
                        continue
                    }

                    if applyShouldProcessFilter, !(await shouldProcessRemoteChat(remoteChat)) {
                        continue
                    }

                    if let localChat = localChatMap[remoteChat.id],
                       localChat.locallyModified || localChat.hasActiveStream || streamingTracker.isStreaming(localChat.id) {
                        continue
                    }

                    let processed = await processRemoteProjectChat(
                        remoteChat,
                        projectId: projectId,
                        localChatMap: localChatMap,
                        errorPrefix: errorPrefix
                    )
                    result = SyncResult(
                        uploaded: result.uploaded,
                        downloaded: result.downloaded + processed.downloaded,
                        deleted: result.deleted,
                        errors: result.errors + processed.errors
                    )
                }

                let nextToken = page.nextToken?.isEmpty == false ? page.nextToken : nil
                continuationToken = page.hasMore ? nextToken : nil
            } while continuationToken != nil

            let status = try await cloudStorage.getProjectChatsSyncStatus(projectId: projectId)
            saveProjectChatSyncStatus(projectId, status)
            await syncCrossScope()
        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                deleted: result.deleted,
                errors: result.errors + ["\(errorPrefix): \(error.localizedDescription)"]
            )
        }

        return result
    }

    private func processRemoteProjectChat(
        _ remoteChat: RemoteChat,
        projectId: String,
        localChatMap: [String: Chat],
        errorPrefix: String
    ) async -> (downloaded: Int, errors: [String]) {
        if let content = remoteChat.content {
            if var decrypted = await decryptRemoteChat(remoteChat, content: content) {
                decrypted.chat.projectId = projectId
                await saveChatToStorage(decrypted.chat)
                await markChatAsSynced(decrypted.chat.id, version: decrypted.chat.syncVersion)
                return (1, [])
            } else {
                let localChat = localChatMap[remoteChat.id]
                let hasValidLocal = localChat.map { !$0.messages.isEmpty && !$0.decryptionFailed } ?? false
                if !hasValidLocal {
                    var placeholder = createEncryptedPlaceholder(remoteChat: remoteChat)
                    placeholder.projectId = projectId
                    await saveChatToStorage(placeholder)
                    return (1, [])
                }
                return (0, [])
            }
        }

        do {
            try await downloadAndSaveRemoteChat(remoteChat, projectId: projectId)
            return (1, [])
        } catch {
            return (0, ["\(errorPrefix) (\(remoteChat.id)): \(error.localizedDescription)"])
        }
    }

    private func backupUnsyncedProjectChats(_ projectId: String) async -> SyncResult {
        var result = SyncResult()

        guard await canWriteToCloud() else {
            return result
        }

        let unsyncedChats = await getUnsyncedChats()
        let unsyncedProjectChats = unsyncedChats.filter { $0.projectId == projectId }

        for chat in unsyncedProjectChats {
            guard !chat.isBlankChat,
                  !chat.messages.isEmpty,
                  !chat.decryptionFailed,
                  !streamingTracker.isStreaming(chat.id) else {
                continue
            }

            do {
                try await uploadCoalescer.enqueueAndWait(chat.id)
                result = SyncResult(
                    uploaded: result.uploaded + 1,
                    downloaded: result.downloaded,
                    deleted: result.deleted,
                    errors: result.errors
                )
            } catch {
                result = SyncResult(
                    uploaded: result.uploaded,
                    downloaded: result.downloaded,
                    deleted: result.deleted,
                    errors: result.errors + ["Failed to backup project chat \(chat.id): \(error.localizedDescription)"]
                )
            }
        }

        return result
    }

    /// Clear cached sync status (call on logout)
    func clearSyncStatus() {
        UserDefaults.standard.removeObject(forKey: syncStatusKey)
        UserDefaults.standard.removeObject(forKey: allChatsSyncStatusKey)
    }

    // MARK: - Sync Status Cache Helpers

    private func getCachedSyncStatus() -> ChatSyncStatus? {
        guard let data = UserDefaults.standard.data(forKey: syncStatusKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatSyncStatus.self, from: data)
    }

    private func saveSyncStatus(count: Int, lastUpdated: String, localCount: Int?) {
        let status = ChatSyncStatus(
            count: count,
            lastUpdated: lastUpdated,
            localCount: localCount
        )
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: syncStatusKey)
        }
    }

    /// Count cloud-eligible chats currently on disk. Used to detect
    /// post-eviction drift in checkSyncStatus and recorded alongside
    /// the cached remote watermark so a future check can spot rows
    /// disappearing from local storage. Returns nil when the storage
    /// read fails so save sites can omit the field rather than
    /// poisoning the cache with a misleading zero.
    private func safeReadLocalChatCount() async -> Int? {
        let chats = await getAllChatsFromStorage()
        return chats.filter { !$0.isLocalOnly }.count
    }

    private func getCachedProjectChatSyncStatus(_ projectId: String) -> ChatSyncStatus? {
        let key = Constants.StorageKeys.Sync.projectChatStatus(projectId: projectId)
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatSyncStatus.self, from: data)
    }

    private func saveProjectChatSyncStatus(_ projectId: String, _ status: ChatSyncStatus) {
        let key = Constants.StorageKeys.Sync.projectChatStatus(projectId: projectId)
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func refreshSyncStatusCache() async {
        if let remoteStatus = try? await cloudStorage.getChatSyncStatus(),
           let lastUpdated = remoteStatus.lastUpdated {
            let localCount = await safeReadLocalChatCount()
            saveSyncStatus(
                count: remoteStatus.count,
                lastUpdated: lastUpdated,
                localCount: localCount
            )
        }
    }

    // MARK: - Cross-Scope Sync

    private func getCachedAllChatsSyncStatus() -> ChatSyncStatus? {
        guard let data = UserDefaults.standard.data(forKey: allChatsSyncStatusKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatSyncStatus.self, from: data)
    }

    private func saveAllChatsSyncStatus(_ status: ChatSyncStatus) {
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: allChatsSyncStatusKey)
        }
    }

    /// Detect and apply cross-scope changes (chats moving between projects or becoming unassigned).
    /// Uses the unscoped all-updated-since endpoint to find chats whose projectId changed.
    private func syncCrossScope() async {
        do {
            let cachedAllStatus = getCachedAllChatsSyncStatus()

            let remoteAllStatus = try await cloudStorage.getAllChatsSyncStatus()

            // If nothing changed globally, skip
            if let cached = cachedAllStatus,
               remoteAllStatus.count == cached.count,
               remoteAllStatus.lastUpdated == cached.lastUpdated {
                saveAllChatsSyncStatus(remoteAllStatus)
                return
            }

            // If we have no cached status, save current and return (first run baseline)
            guard let cachedLastUpdated = cachedAllStatus?.lastUpdated else {
                saveAllChatsSyncStatus(remoteAllStatus)
                return
            }

            let localChats = await getAllChatsFromStorage()
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })

            var continuationToken: String? = nil
            var totalProcessed = 0

            repeat {
                let allUpdated = try await cloudStorage.getAllChatsUpdatedSince(
                    since: cachedLastUpdated,
                    continuationToken: continuationToken
                )

                let remoteChats = allUpdated.conversations
                if remoteChats.isEmpty { break }

                totalProcessed += remoteChats.count

                for remoteChat in remoteChats {
                    let localChat = localChatMap[remoteChat.id]
                    let remoteProjectId = remoteChat.projectId
                    let localProjectId = localChat?.projectId

                    if localChat != nil && remoteProjectId != localProjectId {
                        // Project assignment changed — update local cloud state
                        let userId = await getCurrentUserId()
                        if let userId = userId,
                           var chat = try? await EncryptedFileStorage.cloud.loadChat(chatId: remoteChat.id, userId: userId) {
                            chat.projectId = remoteProjectId
                            try? await EncryptedFileStorage.cloud.saveChat(chat, userId: userId)
                        }
                    } else if localChat == nil, !deletedChatsTracker.isDeleted(remoteChat.id), let content = remoteChat.content {
                        // New chat we don't have locally — decrypt and save it
                        if var decrypted = await decryptRemoteChat(remoteChat, content: content) {
                            decrypted.chat.projectId = remoteProjectId
                            await saveChatToStorage(decrypted.chat)
                            await markChatAsSynced(decrypted.chat.id, version: decrypted.chat.syncVersion)
                        } else {
                            var placeholder = createEncryptedPlaceholder(remoteChat: remoteChat)
                            placeholder.projectId = remoteProjectId
                            await saveChatToStorage(placeholder)
                        }
                    }
                }

                let nextToken = allUpdated.nextContinuationToken?.isEmpty == false ? allUpdated.nextContinuationToken : nil
                continuationToken = allUpdated.hasMore ? nextToken : nil
            } while continuationToken != nil

            #if DEBUG
            if totalProcessed > 0 {
                print("[CloudSync] Cross-scope sync: processed \(totalProcessed) changed chats")
            }
            #endif

            saveAllChatsSyncStatus(remoteAllStatus)
        } catch {
            #if DEBUG
            print("[CloudSync] Failed to sync cross-scope changes: \(error)")
            #endif
        }
    }

    // MARK: - Delete Operations
    
    /// Delete a chat from cloud storage
    func deleteFromCloud(_ chatId: String) async throws {
        // Mark as deleted locally first
        deletedChatsTracker.markAsDeleted(chatId)
        
        // Don't attempt deletion if not authenticated
        guard await cloudStorage.isAuthenticated() else {
            deletedChatsTracker.removeFromDeleted(chatId)
            throw CloudStorageError.authenticationRequired
        }
        
        do {
            try await cloudStorage.deleteChat(chatId)
            
            // Successfully deleted from cloud, can remove from tracker
            deletedChatsTracker.removeFromDeleted(chatId)
            
        } catch {
            deletedChatsTracker.removeFromDeleted(chatId)
            throw error
        }
    }
    
    // MARK: - Storage Helpers
    
    private func loadChatFromStorage(_ chatId: String) async -> Chat? {
        guard let userId = await getCurrentUserId() else { return nil }
        return try? await EncryptedFileStorage.cloud.loadChat(chatId: chatId, userId: userId)
    }

    private func getAllChatsFromStorage() async -> [Chat] {
        let userId = await getCurrentUserId()
        guard let userId = userId else { return [] }
        return (try? await EncryptedFileStorage.cloud.loadAllChats(userId: userId)) ?? []
    }

    private func getUnsyncedChats() async -> [Chat] {
        let userId = await getCurrentUserId()
        guard let userId = userId else { return [] }
        let index = (try? await EncryptedFileStorage.cloud.loadIndex(userId: userId)) ?? []
        let unsyncedIds = index.filter {
            ($0.locallyModified || $0.syncedAt == nil) && !$0.isLocalOnly
        }.map(\.id)
        return (try? await EncryptedFileStorage.cloud.loadChats(chatIds: unsyncedIds, userId: userId)) ?? []
    }

    private func saveChatToStorage(_ storedChat: StoredChat) async {
        let userId = await getCurrentUserId()

        // For R2 data without modelType, set it from current config
        var chatToConvert = storedChat
        if chatToConvert.modelType == nil {
            chatToConvert.modelType = await MainActor.run {
                AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }
        }

        // Convert to Chat - may return nil if models aren't available
        guard let chatToSave = chatToConvert.toChat() else {
            #if DEBUG
            print("Warning: Could not convert StoredChat to Chat - no models available. Skipping chat \(chatToConvert.id)")
            #endif
            return
        }

        await Chat.saveChat(chatToSave, userId: userId)
    }

    /// Upload a chat to cloud and mark it as synced with the enclave's
    /// authoritative version (the new etag), or `chat.syncVersion + 1`
    /// when the enclave didn't return a parseable etag.
    private func uploadAndMarkSynced(_ chat: Chat, idempotencyKey: String) async throws {
        guard !streamingTracker.isStreaming(chat.id) else { return }

        let storedChat = StoredChat(from: chat, syncVersion: chat.syncVersion)
        let result = try await cloudStorage.uploadChat(storedChat, idempotencyKey: idempotencyKey)
        let newVersion = result.syncVersion ?? chat.syncVersion + 1
        if !result.rewrites.isEmpty {
            // Persist the enclave-minted attachment ids before marking
            // the chat synced. If the local rewrite fails we want the
            // next sync pass to retry the upload (so the cloud copy and
            // the on-disk copy converge on the same ids) rather than
            // record success while the local chat still points at
            // pre-upload client ids.
            try await applyAttachmentRewrites(chatId: chat.id, rewrites: result.rewrites)
        }
        await markChatAsSynced(chat.id, version: newVersion)
    }

    /// Apply enclave-minted attachment ids/keys to the freshest local
    /// copy of the chat, matching by the stable client-side id that
    /// the upload captured. The chat object we uploaded is a private
    /// snapshot, so without this step the persistent chat keeps the
    /// pre-upload local ids and the next sync would either re-upload
    /// the same bytes or fail to fetch the cloud copy on another
    /// device.
    private func applyAttachmentRewrites(
        chatId: String,
        rewrites: [CloudStorageService.AttachmentRewrite]
    ) async throws {
        guard let userId = await getCurrentUserId() else { return }
        guard var chat = try await EncryptedFileStorage.cloud.loadChat(
            chatId: chatId,
            userId: userId
        ) else { return }

        let rewriteByClientId = Dictionary(
            uniqueKeysWithValues: rewrites.map { ($0.clientId, $0) }
        )

        var didChange = false
        for msgIdx in chat.messages.indices {
            for attIdx in chat.messages[msgIdx].attachments.indices {
                let clientId = chat.messages[msgIdx].attachments[attIdx].id
                guard let rewrite = rewriteByClientId[clientId] else { continue }
                chat.messages[msgIdx].attachments[attIdx].id = rewrite.serverId
                chat.messages[msgIdx].attachments[attIdx].encryptionKey =
                    rewrite.encryptionKey
                didChange = true
            }
        }

        guard didChange else { return }
        try await EncryptedFileStorage.cloud.saveChat(chat, userId: userId)
    }

    private func markChatAsSynced(_ chatId: String, version: Int) async {
        guard let userId = await getCurrentUserId() else { return }
        try? await EncryptedFileStorage.cloud.updateSyncMetadata(
            chatId: chatId,
            userId: userId,
            syncVersion: version,
            syncedAt: Date(),
            locallyModified: false
        )
    }

    /// Delete local chats that were deleted on another device since `since` timestamp.
    /// Returns the number of chats deleted locally.
    @discardableResult
    private func deleteRemotelyDeletedChats(since: String) async -> Int {
        do {
            let deleted = try await cloudStorage.getDeletedChatsSince(since: since)
            guard !deleted.deletedIds.isEmpty,
                  let userId = await getCurrentUserId() else {
                return 0
            }
            var removedCount = 0
            for id in deleted.deletedIds {
                // Skip chats already absent locally (a prior reconciliation
                // pass handled them, or they were never stored here). This
                // keeps repeated passes idempotent so they never report a
                // phantom deletion and trigger a needless UI reload. A
                // local-only chat lives outside cloud storage, so loadChat
                // returns nil and it is preserved.
                let existing = try? await EncryptedFileStorage.cloud.loadChat(
                    chatId: id,
                    userId: userId
                )
                guard existing != nil else { continue }
                deletedChatsTracker.markAsDeleted(id)
                await deleteChatFromStorage(id)
                removedCount += 1
            }
            return removedCount
        } catch {
            // Non-fatal: continue even if deletion check fails
            return 0
        }
    }

    private func deleteChatFromStorage(_ chatId: String) async {
        guard let userId = await getCurrentUserId() else { return }
        try? await EncryptedFileStorage.cloud.deleteChat(chatId: chatId, userId: userId)
    }
    
    private func getCurrentUserId() async -> String? {
        // Get from Clerk
        if let user = Clerk.shared.user {
            return user.id
        }
        return nil
    }
    
    // MARK: - Validation Methods
    
    /// Determines if a remote chat should be processed/stored locally
    /// Returns false for clearly invalid chats that shouldn't be synced
    private func shouldProcessRemoteChat(_ remoteChat: RemoteChat) async -> Bool {
        // Check if it was recently deleted locally
        if deletedChatsTracker.isDeleted(remoteChat.id) {
            return false
        }
        // Do NOT filter out temporary IDs anymore. Some legacy/migrated chats
        // may have UUID-based IDs and must still be downloaded to avoid data loss.

        // Don't skip based on messageCount - for encrypted chats the server
        // may not accurately know the message count inside the encrypted blob.
        // Let decryption determine if the chat is valid.

        return true
    }
    
    /// Previously: deleted remotely for chats deemed "invalid" (e.g., 0 messages or temp IDs).
    /// Now: no-op to avoid unintended data loss. We never auto-delete based on metadata.
    private func cleanupInvalidRemoteChat(_ remoteChat: RemoteChat) {
        // Intentionally left blank. We keep server state unchanged.
        // If needed in future, handle via explicit tombstones or a confirmed delete flow.
        #if DEBUG
        print("[CloudSync] Skipping auto-delete of remote chat \(remoteChat.id) flagged as invalid.")
        #endif
    }
    
    // MARK: - Retry Decryption Methods

    /// Drop locally-stored placeholders for chats that previously failed to
    /// decrypt and re-pull them from the enclave. The legacy-blob migration
    /// runner is expected to have already rewrapped any server-side rows that
    /// were stuck on a key the client no longer has.
    func retryDecryptionWithNewKey(
        onProgress: ((Int, Int) -> Void)? = nil,
        batchSize: Int = 5
    ) async -> Int {
        let failedChats = await getAllChatsFromStorage().filter { $0.decryptionFailed }
        if failedChats.isEmpty { return 0 }

        let failedIds = Set(failedChats.map { $0.id })

        for (index, chat) in failedChats.enumerated() {
            await deleteChatFromStorage(chat.id)

            if (index + 1) % batchSize == 0 || index == failedChats.count - 1 {
                onProgress?(index + 1, failedChats.count)
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        // Bypass the status-cache short-circuit in smartSync(): the
        // remote rows themselves haven't changed, only our local
        // placeholders. A full pull is required to actually refetch
        // them, otherwise we've just deleted the failed chats and
        // left nothing in their place.
        _ = await syncAllChats()

        // Only count chats that were actually re-fetched and decrypted
        // successfully. Chats that were deleted upstream stay gone and
        // must not be reported as "recovered".
        let afterSync = await getAllChatsFromStorage()
        let recovered = afterSync.filter { failedIds.contains($0.id) && !$0.decryptionFailed }
        return recovered.count
    }

    
    /// Re-encrypt all local chats with new key and upload to cloud
    func reencryptAndUploadChats() async -> (reencrypted: Int, uploaded: Int, errors: [String]) {
        var result = (reencrypted: 0, uploaded: 0, errors: [String]())

        guard await canWriteToCloud() else {
            return result
        }
        
        // Get all local chats
        let allChats = await getAllChatsFromStorage()
        
        
        // Initialize encryption with new key
        do {
            _ = try await encryptionService.initialize()
        } catch {
            result.errors.append("Failed to initialize encryption: \(error)")
            return result
        }
        
        for chat in allChats {
            // Skip blank and empty chats
            if chat.isBlankChat || chat.messages.isEmpty { continue }

            do {
                // Re-encrypt the chat with the new key by forcing a sync
                guard await cloudStorage.isAuthenticated() else { continue }
                
                var chatToReencrypt = chat
                chatToReencrypt.locallyModified = true
                
                // Save locally then upload (will be encrypted with new key)
                await saveChatToStorage(StoredChat(from: chatToReencrypt))
                try await uploadCoalescer.enqueueAndWait(chatToReencrypt.id)
                
                result.uploaded += 1
                result.reencrypted += 1
                
            } catch {
                let errorMsg = "Failed to re-encrypt chat \(chat.id): \(error)"
                result.errors.append(errorMsg)
            }
        }
        
        
        return result
    }

}


