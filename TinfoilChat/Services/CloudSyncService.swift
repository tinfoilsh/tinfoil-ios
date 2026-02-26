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
    }

    private var states: [String: ChatUploadState] = [:]
    private let uploadFn: @Sendable (String) async throws -> Void

    init(uploadFn: @escaping @Sendable (String) async throws -> Void) {
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

    private func runWorker(_ chatId: String) async {
        while states[chatId]?.dirty == true {
            states[chatId]?.dirty = false

            await uploadWithRetry(chatId)
        }

        // Notify waiters and clean up in a single access
        let waiters = states[chatId]?.waiters ?? []
        for waiter in waiters {
            waiter.resume()
        }

        let failureCount = states[chatId]?.failureCount ?? 0
        if failureCount == 0 {
            states.removeValue(forKey: chatId)
        } else {
            states[chatId]?.workerRunning = false
            states[chatId]?.waiters = []
        }
    }

    private func uploadWithRetry(_ chatId: String) async {
        for attempt in 0...Constants.Sync.uploadMaxRetries {
            do {
                try await uploadFn(chatId)
                states[chatId]?.failureCount = 0
                return
            } catch {
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
                    return
                }
            }
        }
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
        UploadCoalescer { [weak self] chatId in
            try await self?.doBackupChat(chatId)
        }
    }()
    private var streamingCallbacks: Set<String> = []
    private let cloudStorage = CloudStorageService.shared
    private let encryptionService = EncryptionService.shared
    private let deletedChatsTracker = DeletedChatsTracker.shared
    private let streamingTracker = StreamingTracker.shared
    // UserDefaults keys for sync status caches
    private let syncStatusKey = "tinfoil-chat-sync-status"
    private let allChatsSyncStatusKey = "tinfoil-all-chats-sync-status"

    private init() {}
    
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
        cloudStorage.setTokenGetter(tokenGetter)
        ProfileSyncService.shared.setTokenGetter(tokenGetter)
        
    }
    
    // MARK: - Single Chat Backup
    
    /// Backup a single chat to the cloud, coalescing rapid successive calls
    func backupChat(_ chatId: String, ensureLatestUpload: Bool = false) async {
        // Don't attempt backup if not authenticated
        guard await cloudStorage.isAuthenticated() else {
            return
        }

        await uploadCoalescer.enqueue(chatId)

        if ensureLatestUpload {
            await uploadCoalescer.waitForUpload(chatId)
        }
    }
    
    private func doBackupChat(_ chatId: String) async throws {
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
        
        
        // Don't sync blank, empty, or decryption failure chats
        if chat.isBlankChat || chat.messages.isEmpty || chat.decryptionFailed || chat.encryptedData != nil {
            return
        }

        // Double-check streaming status right before upload
        if streamingTracker.isStreaming(chatId) {
            return
        }
        
        try await uploadAndMarkSynced(chat)
        
    }
    
    // MARK: - Bulk Sync Operations
    
    /// Backup all unsynced chats
    func backupUnsyncedChats() async -> SyncResult {
        var result = SyncResult()
        
        let unsyncedChats = await getUnsyncedChats()
        
        
        // Filter out blank, empty, decryption failure, and streaming chats
        var chatsToSync: [Chat] = []
        for chat in unsyncedChats {
            if !chat.isBlankChat && !chat.messages.isEmpty && !chat.decryptionFailed && chat.encryptedData == nil {
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
                try await uploadAndMarkSynced(chat)
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
                    let placeholder = createEncryptedPlaceholder(
                        remoteChat: remoteChat,
                        encryptedContent: content
                    )
                    downloadedChats.append(placeholder)
                }
            }

            // Sort by creation date (newest first)
            downloadedChats.sort { $0.createdAt > $1.createdAt }
            
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
        
        // Sort by creation date (newest first)
        let sortedChats = allChats.sorted { $0.createdAt > $1.createdAt }
        
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
    
    /// Decrypt a remote chat's content, apply server metadata dates, and set a default model if needed.
    /// Returns the decrypted `StoredChat` and whether a fallback key was used (indicating reencryption is needed).
    /// Returns `nil` on failure — callers are responsible for creating an encrypted placeholder.
    struct DecryptedChatResult {
        var chat: StoredChat
        let usedFallbackKey: Bool
    }

    private func decryptRemoteChat(
        _ remoteChat: RemoteChat,
        content: String
    ) async -> DecryptedChatResult? {
        let formatVersion = remoteChat.formatVersion ?? 0

        do {
            let decryptionResult: DecryptionResult<StoredChat>

            if formatVersion == 1 {
                // v1: content is base64-encoded binary
                guard let binaryData = Data(base64Encoded: content) else { return nil }
                decryptionResult = try encryptionService.decryptV1(binaryData, as: StoredChat.self)
            } else {
                // v0: content is a JSON-encoded EncryptedData envelope
                guard let contentData = content.data(using: .utf8) else { return nil }
                let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)
                decryptionResult = try await encryptionService.decrypt(encrypted, as: StoredChat.self)
            }

            var decryptedChat = decryptionResult.value
            decryptedChat.formatVersion = formatVersion

            // Prefer blob's createdAt (matches React's `decrypted.createdAt ?? remote.createdAt`).
            // StoredChat decoder falls back to Date() on parse failure — detect that
            // by checking if the blob date is within the last few seconds.
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

            return DecryptedChatResult(chat: decryptedChat, usedFallbackKey: decryptionResult.usedFallbackKey)
        } catch {
            return nil
        }
    }

    /// Create encrypted placeholder for chats that failed to decrypt
    private func createEncryptedPlaceholder(
        remoteChat: RemoteChat,
        encryptedContent: String
    ) -> StoredChat {
        StoredChat.encryptedPlaceholder(
            id: remoteChat.id,
            createdAt: parseISODate(remoteChat.createdAt) ?? Date(),
            updatedAt: parseISODate(remoteChat.updatedAt) ?? Date(),
            formatVersion: remoteChat.formatVersion ?? 0,
            encryptedData: encryptedContent
        )
    }
    
    /// Download a remote chat by ID, apply metadata dates, and save locally.
    /// Returns `true` if the chat was downloaded and saved, `false` on failure.
    private func downloadAndSaveRemoteChat(_ remoteChat: RemoteChat) async throws {
        guard var downloadedChat = try await cloudStorage.downloadChat(remoteChat.id) else {
            return
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
    func syncAllChats() async -> SyncResult {
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

        let result = await doSyncAllChats()
        syncErrors = result.errors
        return result
    }

    private func doSyncAllChats() async -> SyncResult {
        var result = SyncResult()

        // First, backup any unsynced local changes
        let backupResult = await backupUnsyncedChats()
        result = SyncResult(
            uploaded: backupResult.uploaded,
            downloaded: 0,
            errors: backupResult.errors
        )

        // Then, get list of remote chats with content
        do {
            let remoteList = try await cloudStorage.listChats(
                limit: Constants.Pagination.chatsPerPage,
                includeContent: true
            )

            let localChats = await getAllChatsFromStorage()

            // Initialize encryption if available; continue even without a key so we can at least
            // fetch metadata and store encrypted placeholders. Decryption will be attempted per-chat.
            _ = try? await encryptionService.initialize()

            // Create maps for easy lookup
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })
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
                                let placeholder = createEncryptedPlaceholder(
                                    remoteChat: remoteChat,
                                    encryptedContent: content
                                )
                                await saveChatToStorage(placeholder)
                                result = SyncResult(
                                    uploaded: result.uploaded,
                                    downloaded: result.downloaded + 1,
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
                                errors: result.errors
                            )
                        } catch {
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded,
                                errors: result.errors + ["Failed to download chat \(remoteChat.id): \(error.localizedDescription)"]
                            )
                        }
                    }
                }
            }

            // Delete local chats that were deleted on another device
            var deletedCount = 0
            if let cachedStatus = getCachedSyncStatus(),
               let lastUpdated = cachedStatus.lastUpdated {
                deletedCount = await deleteRemotelyDeletedChats(since: lastUpdated)
            }

            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                deleted: result.deleted + deletedCount,
                errors: result.errors
            )

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

        // Backup any unsynced local changes first (matches doSyncAllChats behavior)
        let backupResult = await backupUnsyncedChats()
        result = SyncResult(
            uploaded: backupResult.uploaded,
            downloaded: 0,
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
                                errors: result.errors
                            )
                        } else {
                            // Only save a placeholder when no valid local copy exists.
                            let localChat = localChatMap[remoteChat.id]
                            let hasValidLocal = localChat.map { !$0.messages.isEmpty && !$0.decryptionFailed } ?? false
                            if !hasValidLocal {
                                let placeholder = createEncryptedPlaceholder(
                                    remoteChat: remoteChat,
                                    encryptedContent: content
                                )
                                await saveChatToStorage(placeholder)
                                result = SyncResult(
                                    uploaded: result.uploaded,
                                    downloaded: result.downloaded + 1,
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
                                errors: result.errors
                            )
                        } catch {
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded,
                                errors: result.errors + ["Failed to download chat \(remoteChat.id): \(error.localizedDescription)"]
                            )
                        }
                    }
                }

                let nextToken = changedChats.nextContinuationToken?.isEmpty == false ? changedChats.nextContinuationToken : nil
                hasMore = changedChats.hasMore && nextToken != nil
                continuationToken = nextToken
            }

            // Delete local chats that were deleted on another device
            let deletedCount = await deleteRemotelyDeletedChats(since: since)
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                deleted: result.deleted + deletedCount,
                errors: result.errors
            )

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
                errors: result.errors + deltaResult.errors
            )

            if !deltaResult.errors.isEmpty {
                // Delta sync failed, fall back to full sync
                let fullResult = await doSyncAllChats()
                result = SyncResult(
                    uploaded: result.uploaded + fullResult.uploaded,
                    downloaded: result.downloaded + fullResult.downloaded,
                    errors: fullResult.errors
                )
            }
        } else {
            // Count changed, local changes, or no cached status - need full sync
            let fullResult = await doSyncAllChats()
            result = SyncResult(
                uploaded: result.uploaded + fullResult.uploaded,
                downloaded: result.downloaded + fullResult.downloaded,
                errors: result.errors + fullResult.errors
            )
        }

        syncErrors = result.errors
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

    private func saveSyncStatus(count: Int, lastUpdated: String) {
        let status = ChatSyncStatus(count: count, lastUpdated: lastUpdated)
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: syncStatusKey)
        }
    }

    private func refreshSyncStatusCache() async {
        if let remoteStatus = try? await cloudStorage.getChatSyncStatus(),
           let lastUpdated = remoteStatus.lastUpdated {
            saveSyncStatus(count: remoteStatus.count, lastUpdated: lastUpdated)
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
                            var placeholder = createEncryptedPlaceholder(
                                remoteChat: remoteChat,
                                encryptedContent: content
                            )
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
            return
        }
        
        do {
            try await cloudStorage.deleteChat(chatId)
            
            // Successfully deleted from cloud, can remove from tracker
            deletedChatsTracker.removeFromDeleted(chatId)
            
        } catch {
            // Silently fail if no auth token set
            if let error = error as? CloudStorageError,
               error == .authenticationRequired {
                return
            }
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
        let unsyncedIds = index.filter { $0.locallyModified || $0.syncedAt == nil }.map(\.id)
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

    /// Upload a chat to cloud and mark it as synced with an incremented version.
    /// Encapsulates the two-step "upload current version, increment after success" protocol.
    private func uploadAndMarkSynced(_ chat: Chat) async throws {
        let storedChat = StoredChat(from: chat, syncVersion: chat.syncVersion)
        try await cloudStorage.uploadChat(storedChat)
        await markChatAsSynced(chat.id, version: chat.syncVersion + 1)
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
            for id in deleted.deletedIds {
                await deleteChatFromStorage(id)
            }
            return deleted.deletedIds.count
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

    /// Retry decryption for chats that failed to decrypt
    func retryDecryptionWithNewKey(
        onProgress: ((Int, Int) -> Void)? = nil,
        batchSize: Int = 5
    ) async -> Int {
        var decryptedCount = 0

        // Get all chats that have encrypted data
        let chatsWithEncryptedData = await getChatsWithEncryptedData()

        // Process chats sequentially to avoid connection exhaustion
        for (index, chat) in chatsWithEncryptedData.enumerated() {
            guard let encryptedData = chat.encryptedData else { continue }

            do {
                let decryptionResult: DecryptionResult<StoredChat>

                if chat.formatVersion == 1 {
                    // v1: encryptedData is base64-encoded binary
                    guard let binaryData = Data(base64Encoded: encryptedData) else {
                        throw CloudSyncError.invalidBase64
                    }
                    decryptionResult = try encryptionService.decryptV1(binaryData, as: StoredChat.self)
                } else {
                    // v0: encryptedData is a JSON-encoded EncryptedData envelope
                    guard let contentData = encryptedData.data(using: .utf8) else {
                        throw CloudSyncError.invalidBase64
                    }
                    let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)
                    decryptionResult = try await encryptionService.decrypt(encrypted, as: StoredChat.self)
                }

                let decryptedData = decryptionResult.value

                // Get a model type for decrypted chat (use existing or get default)
                let modelForChat: ModelType
                if let existingModel = decryptedData.modelType {
                    modelForChat = existingModel
                } else {
                    guard let defaultModel = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first else {
                        continue
                    }
                    modelForChat = defaultModel
                }

                // Use decrypted content but preserve metadata dates and format version
                let updatedChat = StoredChat(
                    from: Chat(
                        id: chat.id,
                        title: decryptedData.title,
                        messages: decryptedData.messages,
                        createdAt: chat.createdAt,
                        modelType: modelForChat,
                        language: decryptedData.language,
                        userId: decryptedData.userId,
                        syncVersion: chat.syncVersion,
                        syncedAt: chat.syncedAt,
                        locallyModified: false,
                        updatedAt: chat.updatedAt,
                        decryptionFailed: false,
                        encryptedData: nil,
                        formatVersion: chat.formatVersion,
                        isLocalOnly: chat.isLocalOnly
                    )
                )

                await saveChatToStorage(updatedChat)
                decryptedCount += 1
            } catch {
                // Continue to next chat on failure
            }

            // Report progress periodically
            if (index + 1) % batchSize == 0 || index == chatsWithEncryptedData.count - 1 {
                onProgress?(index + 1, chatsWithEncryptedData.count)
                // Yield to the event loop
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
        }
        
        return decryptedCount
    }
    
    /// Get all chats that have encrypted data stored
    private func getChatsWithEncryptedData() async -> [Chat] {
        let allChats = await getAllChatsFromStorage()
        return allChats.filter { $0.decryptionFailed && $0.encryptedData != nil }
    }
    
    /// Re-encrypt all local chats with new key and upload to cloud
    func reencryptAndUploadChats() async -> (reencrypted: Int, uploaded: Int, errors: [String]) {
        var result = (reencrypted: 0, uploaded: 0, errors: [String]())
        
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
                try await uploadAndMarkSynced(chatToReencrypt)
                
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

// MARK: - Cloud Sync Errors

enum CloudSyncError: LocalizedError {
    case syncInProgress
    case authenticationRequired
    case invalidBase64
    case encryptionFailed
    case decryptionFailed
    
    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            return "Sync already in progress"
        case .authenticationRequired:
            return "Authentication required for sync"
        case .invalidBase64:
            return "Invalid base64 data"
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data"
        }
    }
}
