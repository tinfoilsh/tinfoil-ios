//
//  CloudSyncService.swift
//  TinfoilChat
//
//  Main service for orchestrating cloud synchronization
//

import Foundation
import Combine
import Clerk

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

private actor ReencryptionTracker {
    private var inProgress: Set<String> = []

    func startIfNeeded(for chatId: String) -> Bool {
        if inProgress.contains(chatId) {
            return false
        }
        inProgress.insert(chatId)
        return true
    }

    func finish(for chatId: String) {
        inProgress.remove(chatId)
    }
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

        // Notify waiters
        if let waiters = states[chatId]?.waiters {
            for waiter in waiters {
                waiter.resume()
            }
        }

        // Clean up state if no failures
        if states[chatId]?.failureCount == 0 {
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
                states[chatId]?.failureCount = (states[chatId]?.failureCount ?? 0) + 1

                if attempt == Constants.Sync.uploadMaxRetries {
                    break
                }

                let delay = min(
                    Constants.Sync.uploadBaseDelaySeconds * pow(2.0, Double(attempt)),
                    Constants.Sync.uploadMaxDelaySeconds
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // If dirty was set during backoff, return early to upload fresh data
                if states[chatId]?.dirty == true {
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
    private let reencryptionTracker = ReencryptionTracker()

    // UserDefaults key for sync status cache
    private let syncStatusKey = "tinfoil-chat-sync-status"

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
                    try await Clerk.shared.load()
                }
                
                // Get fresh token from session
                if let session = Clerk.shared.session {
                    // Try to get a fresh token first (refresh if needed)
                    if let token = try? await session.getToken() {
                        return token.jwt
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
        
        
        // Don't sync blank chats or decryption failure placeholders
        if chat.isBlankChat || chat.messages.isEmpty || chat.decryptionFailed || chat.encryptedData != nil {
            return
        }

        // Double-check streaming status right before upload
        if streamingTracker.isStreaming(chatId) {
            return
        }
        
        // Convert to StoredChat and upload
        let storedChat = StoredChat(from: chat, syncVersion: chat.syncVersion + 1)
        try await cloudStorage.uploadChat(storedChat)
        
        // Mark as synced
        await markChatAsSynced(chatId, version: storedChat.syncVersion)
        
    }
    
    // MARK: - Bulk Sync Operations
    
    /// Backup all unsynced chats
    func backupUnsyncedChats() async -> SyncResult {
        var result = SyncResult()
        
        let unsyncedChats = await getUnsyncedChats()
        
        
        // Filter out blank chats, empty chats (decryption failure placeholders), and streaming chats
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
                let storedChat = StoredChat(from: chat, syncVersion: chat.syncVersion + 1)
                try await cloudStorage.uploadChat(storedChat)
                await markChatAsSynced(chat.id, version: storedChat.syncVersion)
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
            
            var chatsNeedingReencryption: [StoredChat] = []

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

                do {
                    // Parse and decrypt the content
                    guard let contentData = content.data(using: .utf8) else {
                        throw CloudSyncError.invalidBase64
                    }

                    let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)

                    // Try to decrypt
                    do {
                        let decryptionResult = try await encryptionService.decrypt(encrypted, as: StoredChat.self)
                        var decryptedChat = decryptionResult.value

                        // Use dates from metadata for consistency
                        if let createdDate = parseISODate(remoteChat.createdAt) {
                            decryptedChat.createdAt = createdDate
                        }
                        if let updatedDate = parseISODate(remoteChat.updatedAt) {
                            decryptedChat.updatedAt = updatedDate
                        }

                        // Set default model if missing (for R2 data)
                        if decryptedChat.modelType == nil {
                            decryptedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
                        }

                        downloadedChats.append(decryptedChat)
                        if decryptionResult.usedFallbackKey {
                            chatsNeedingReencryption.append(decryptedChat)
                        }
                    } catch {
                        // Decryption failed - return encrypted placeholder
                        let placeholder = await createEncryptedPlaceholder(
                            remoteChat: remoteChat,
                            encryptedContent: content
                        )
                        downloadedChats.append(placeholder)
                    }
                } catch {
                    // Failed to parse encrypted data
                    let placeholder = await createEncryptedPlaceholder(
                        remoteChat: remoteChat,
                        encryptedContent: content
                    )
                    downloadedChats.append(placeholder)
                }
            }
            
            for chat in chatsNeedingReencryption {
                queueReencryption(for: chat, persistLocal: false)
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
    
    /// Create encrypted placeholder for chats that failed to decrypt
    private func createEncryptedPlaceholder(
        remoteChat: RemoteChat,
        encryptedContent: String
    ) async -> StoredChat {
        let createdDate = parseISODate(remoteChat.createdAt) ?? Date()
        let updatedDate = parseISODate(remoteChat.updatedAt) ?? Date()
        
        var placeholderChat = StoredChat(
            from: Chat.create(
                id: remoteChat.id,
                title: "Encrypted",
                messages: [],
                createdAt: createdDate
            )
        )
        placeholderChat.decryptionFailed = true
        placeholderChat.encryptedData = encryptedContent
        placeholderChat.updatedAt = updatedDate
        
        return placeholderChat
    }
    
    /// Download a remote chat by ID, apply metadata dates, and save locally.
    /// Returns `true` if the chat was downloaded and saved, `false` on failure.
    private func downloadAndSaveRemoteChat(_ remoteChat: RemoteChat) async throws {
        guard var downloadedChat = try await cloudStorage.downloadChat(remoteChat.id) else {
            return
        }

        if let createdDate = parseISODate(remoteChat.createdAt) {
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
            var chatsNeedingReencryption: [StoredChat] = []

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
                        do {
                            // Parse and decrypt the content (JSON string format)
                            guard let contentData = content.data(using: .utf8) else {
                                throw CloudSyncError.invalidBase64
                            }

                            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)

                            // Try to decrypt the chat data
                            do {
                                let decryptionResult = try await encryptionService.decrypt(encrypted, as: StoredChat.self)
                                var decryptedChat = decryptionResult.value

                                // Double-check: Even if decryption succeeded, validate the content
                                if decryptedChat.messages.isEmpty {
                                    cleanupInvalidRemoteChat(remoteChat)
                                    continue
                                }

                                // IMPORTANT: Use dates from metadata, not from decrypted data
                                // This ensures consistency and prevents date corruption
                                if let createdDate = parseISODate(remoteChat.createdAt) {
                                    decryptedChat.createdAt = createdDate
                                }
                                if let updatedDate = parseISODate(remoteChat.updatedAt) {
                                    decryptedChat.updatedAt = updatedDate
                                }

                                // For R2 data, ensure modelType is set
                                if decryptedChat.modelType == nil {
                                    decryptedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
                                }

                                await saveChatToStorage(decryptedChat)
                                await markChatAsSynced(decryptedChat.id, version: decryptedChat.syncVersion)
                                result = SyncResult(
                                    uploaded: result.uploaded,
                                    downloaded: result.downloaded + 1,
                                    errors: result.errors
                                )
                                if decryptionResult.usedFallbackKey {
                                    chatsNeedingReencryption.append(decryptedChat)
                                }
                            } catch {
                                // Decryption failed - store as encrypted placeholder for later retry
                                // Use dates from metadata
                                let createdDate = parseISODate(remoteChat.createdAt) ?? Date()
                                let updatedDate = parseISODate(remoteChat.updatedAt) ?? Date()

                                // Create placeholder with encrypted data
                                var placeholderChat = StoredChat(
                                    from: Chat.create(
                                        id: remoteChat.id,
                                        title: "Encrypted",
                                        messages: [],
                                        createdAt: createdDate
                                    )
                                )
                                placeholderChat.decryptionFailed = true
                                placeholderChat.encryptedData = content
                                placeholderChat.updatedAt = updatedDate

                                await saveChatToStorage(placeholderChat)
                                result = SyncResult(
                                    uploaded: result.uploaded,
                                    downloaded: result.downloaded + 1,
                                    errors: result.errors
                                )
                            }
                        } catch {
                            // Even if we can't parse the encrypted data, store it for later
                            // Extract timestamp from the chat ID to use as createdAt
                            // Format: {reverseTimestamp}_{randomSuffix}
                            let createdDate: Date
                            if let underscoreIndex = remoteChat.id.firstIndex(of: "_"),
                               let timestamp = Int(remoteChat.id.prefix(upTo: underscoreIndex)) {
                                // Convert reversed timestamp to actual timestamp
                                let actualTimestamp = Constants.Sync.maxReverseTimestamp - timestamp
                                createdDate = Date(timeIntervalSince1970: Double(actualTimestamp) / 1000.0)
                            } else {
                                // Fallback to ISO date parsing if ID format is different
                                createdDate = parseISODate(remoteChat.createdAt) ?? Date()
                            }

                            let updatedDate = parseISODate(remoteChat.updatedAt) ?? Date()

                            var placeholderChat = StoredChat(
                                from: Chat.create(
                                    id: remoteChat.id,
                                    title: "Encrypted",
                                    messages: [],
                                    createdAt: createdDate
                                )
                            )
                            placeholderChat.decryptionFailed = true
                            placeholderChat.encryptedData = content
                            placeholderChat.updatedAt = updatedDate

                            await saveChatToStorage(placeholderChat)
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded + 1,
                                errors: result.errors
                            )
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

            for chat in chatsNeedingReencryption {
                queueReencryption(for: chat, persistLocal: true)
            }

            // Delete local chats that were deleted on another device
            if let cachedStatus = getCachedSyncStatus(),
               let lastUpdated = cachedStatus.lastUpdated {
                await deleteRemotelyDeletedChats(since: lastUpdated)
            }

            // Refresh cached sync status so subsequent smart-syncs have up-to-date info
            await refreshSyncStatusCache()

        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
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
            let changedChats = try await cloudStorage.getChatsUpdatedSince(since: since, includeContent: true)

            _ = try? await encryptionService.initialize()

            var chatsNeedingReencryption: [StoredChat] = []

            let localChats = await getAllChatsFromStorage()
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })

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
                    do {
                        guard let contentData = content.data(using: .utf8) else {
                            throw CloudSyncError.invalidBase64
                        }

                        let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)

                        do {
                            let decryptionResult = try await encryptionService.decrypt(encrypted, as: StoredChat.self)
                            var decryptedChat = decryptionResult.value

                            if let createdDate = parseISODate(remoteChat.createdAt) {
                                decryptedChat.createdAt = createdDate
                            }
                            if let updatedDate = parseISODate(remoteChat.updatedAt) {
                                decryptedChat.updatedAt = updatedDate
                            }

                            if decryptedChat.modelType == nil {
                                decryptedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
                            }

                            await saveChatToStorage(decryptedChat)
                            await markChatAsSynced(decryptedChat.id, version: decryptedChat.syncVersion)
                            result = SyncResult(
                                uploaded: result.uploaded,
                                downloaded: result.downloaded + 1,
                                errors: result.errors
                            )

                            if decryptionResult.usedFallbackKey {
                                chatsNeedingReencryption.append(decryptedChat)
                            }
                        } catch {
                            let placeholder = await createEncryptedPlaceholder(
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
                    } catch {
                        let placeholder = await createEncryptedPlaceholder(
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

            for chat in chatsNeedingReencryption {
                queueReencryption(for: chat, persistLocal: true)
            }

            // Delete local chats that were deleted on another device
            await deleteRemotelyDeletedChats(since: since)

            // Refresh cached sync status so subsequent smart-syncs have up-to-date info
            await refreshSyncStatusCache()
        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
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
        let chats = Chat.loadFromDefaults(userId: await getCurrentUserId())
        return chats.first { $0.id == chatId }
    }
    
    private func getAllChatsFromStorage() async -> [Chat] {
        return Chat.loadFromDefaults(userId: await getCurrentUserId())
    }
    
    private func getUnsyncedChats() async -> [Chat] {
        let allChats = await getAllChatsFromStorage()
        // Return chats that are locally modified or never synced
        return allChats.filter { chat in
            chat.locallyModified || chat.syncedAt == nil
        }
    }
    
    private func saveChatToStorage(_ storedChat: StoredChat) async {
        let userId = await getCurrentUserId()
        
        var chats = await getAllChatsFromStorage()

        // Remove existing chat if present
        chats.removeAll { $0.id == storedChat.id }
        
        // For R2 data without modelType, set it from current config
        var chatToConvert = storedChat
        if chatToConvert.modelType == nil {
            chatToConvert.modelType = await MainActor.run {
                AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }
        }
        
        // Convert to Chat - may return nil if models aren't available
        guard var chatToSave = chatToConvert.toChat() else {
            #if DEBUG
            print("Warning: Could not convert StoredChat to Chat - no models available. Skipping chat \(chatToConvert.id)")
            #endif
            return
        }

        // Add updated chat
        chats.append(chatToSave)
        
        // Filter out blank chats before saving (matches ChatViewModel.saveChats behavior)
        // BUT keep encrypted chats that failed to decrypt (they have decryptionFailed flag)
        let chatsToSave = chats.filter { chat in
            !chat.messages.isEmpty || chat.decryptionFailed
        }
        
        // Save back to defaults
        Chat.saveToDefaults(chatsToSave, userId: userId)
    }
    
    private func markChatAsSynced(_ chatId: String, version: Int) async {
        var chats = await getAllChatsFromStorage()
        
        if let index = chats.firstIndex(where: { $0.id == chatId }) {
            chats[index].syncVersion = version
            chats[index].syncedAt = Date()
            chats[index].locallyModified = false
            
            // Filter out blank chats before saving (matches ChatViewModel.saveChats behavior)
            // BUT keep encrypted chats that failed to decrypt
            let chatsToSave = chats.filter { !$0.messages.isEmpty || $0.decryptionFailed }
            Chat.saveToDefaults(chatsToSave, userId: await getCurrentUserId())
        }
    }

    private func queueReencryption(for chat: StoredChat, persistLocal: Bool) {
        Task { [weak self] in
            guard let self = self else { return }
            let shouldStart = await self.reencryptionTracker.startIfNeeded(for: chat.id)
            guard shouldStart else { return }
            await self.performReencryption(for: chat, persistLocal: persistLocal)
            await self.reencryptionTracker.finish(for: chat.id)
        }
    }

    private func performReencryption(for chat: StoredChat, persistLocal: Bool) async {
        guard await cloudStorage.isAuthenticated() else { return }

        // Ensure encryption service is initialized with the current default key
        _ = try? await encryptionService.initialize()

        // Skip placeholder chats that still lack content
        guard !chat.messages.isEmpty else { return }

        // Convert to Chat for re-encryption - may fail if models aren't available
        guard var chatForUpload = chat.toChat() else {
            #if DEBUG
            print("Warning: Could not convert StoredChat to Chat for re-encryption - no models available. Skipping chat \(chat.id)")
            #endif
            return
        }

        chatForUpload.decryptionFailed = false
        chatForUpload.encryptedData = nil
        chatForUpload.locallyModified = true
        chatForUpload.updatedAt = Date()

        let newVersion = chatForUpload.syncVersion + 1
        chatForUpload.syncVersion = newVersion

        let storedForUpload = StoredChat(from: chatForUpload, syncVersion: newVersion)

        if persistLocal {
            await saveChatToStorage(storedForUpload)
        }

        do {
            try await cloudStorage.uploadChat(storedForUpload)
            await markChatAsSynced(chatForUpload.id, version: newVersion)
        } catch {
            #if DEBUG
            print("[CloudSync] Failed to re-encrypt chat \(chat.id): \(error)")
            #endif
        }
    }

    /// Delete local chats that were deleted on another device since `since` timestamp.
    private func deleteRemotelyDeletedChats(since: String) async {
        do {
            let deleted = try await cloudStorage.getDeletedChatsSince(since: since)
            for id in deleted.deletedIds {
                await deleteChatFromStorage(id)
            }
        } catch {
            // Non-fatal: continue even if deletion check fails
        }
    }

    private func deleteChatFromStorage(_ chatId: String) async {
        var chats = await getAllChatsFromStorage()
        chats.removeAll { $0.id == chatId }
        
        // Filter out blank chats before saving (matches ChatViewModel.saveChats behavior)
        // BUT keep encrypted chats that failed to decrypt
        let chatsToSave = chats.filter { !$0.messages.isEmpty || $0.decryptionFailed }
        Chat.saveToDefaults(chatsToSave, userId: await getCurrentUserId())
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
                // Parse the stored encrypted data
                guard let contentData = encryptedData.data(using: .utf8) else {
                    throw CloudSyncError.invalidBase64
                }

                let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)

                // Decrypt the chat data
                let decryptionResult = try await encryptionService.decrypt(encrypted, as: StoredChat.self)
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

                // Use decrypted content but preserve metadata dates
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
                        encryptedData: nil
                    )
                )

                await saveChatToStorage(updatedChat)
                if decryptionResult.usedFallbackKey {
                    queueReencryption(for: updatedChat, persistLocal: true)
                }
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
            // Skip blank chats and chats with no messages (decryption failure placeholders)
            if chat.isBlankChat || chat.messages.isEmpty { continue }

            do {
                // Re-encrypt the chat with the new key by forcing a sync
                guard await cloudStorage.isAuthenticated() else { continue }
                
                // Increment sync version to force upload
                var chatToReencrypt = chat
                chatToReencrypt.syncVersion = chat.syncVersion + 1
                chatToReencrypt.locallyModified = true
                
                // Save locally with new sync version
                await saveChatToStorage(StoredChat(from: chatToReencrypt))
                
                // Upload to cloud (will be encrypted with new key)
                let storedChat = StoredChat(from: chatToReencrypt)
                try await cloudStorage.uploadChat(storedChat)
                await markChatAsSynced(chatToReencrypt.id, version: chatToReencrypt.syncVersion)
                
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
