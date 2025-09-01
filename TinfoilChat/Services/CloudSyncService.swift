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
    private var uploadQueue: [String: Task<Void, Error>] = [:]
    private var streamingCallbacks: Set<String> = []
    private let r2Storage = R2StorageService.shared
    private let encryptionService = EncryptionService.shared
    private let deletedChatsTracker = DeletedChatsTracker.shared
    private let streamingTracker = StreamingTracker.shared
    
    // Constants
    
    private init() {}
    
    // MARK: - Initialization
    
    /// Initialize the sync service with auth token getter
    func initialize() async throws {
        // Initialize encryption service
        _ = try await encryptionService.initialize()
        
        // Set up custom token getter for R2 storage that ensures Clerk is loaded
        r2Storage.setTokenGetter { 
            do {
                // Check if Clerk has a publishable key
                guard Clerk.shared.publishableKey != nil else {
                    return nil
                }
                
                // Ensure Clerk is loaded
                if !Clerk.shared.isLoaded {
                    try await Clerk.shared.load()
                }
                
                // Get fresh token from session
                if let session = Clerk.shared.session {
                    if let token = try? await session.getToken() {
                        return token.jwt
                    } else if let tokenResource = session.lastActiveToken {
                        return tokenResource.jwt
                    }
                }
                
                return nil
            } catch {
                return nil
            }
        }
        
    }
    
    // MARK: - Single Chat Backup
    
    /// Backup a single chat to the cloud with rate limiting
    func backupChat(_ chatId: String) async throws {
        // Don't attempt backup if not authenticated
        guard await r2Storage.isAuthenticated() else {
            return
        }
        
        // Check if there's already an upload in progress for this chat
        if let existingUpload = uploadQueue[chatId] {
            try await existingUpload.value
            return
        }
        
        // Create the upload task
        let uploadTask = Task<Void, Error> { [weak self] in
            try await self?.doBackupChat(chatId)
        }
        
        // Store in queue
        uploadQueue[chatId] = uploadTask
        
        // Clean up the queue when done
        defer {
            uploadQueue.removeValue(forKey: chatId)
        }
        
        try await uploadTask.value
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
                    try? await self?.backupChat(chatId)
                }
            }
            
            return
        }
        
        // Load chat from storage
        guard let chat = await loadChatFromStorage(chatId) else {
            return // Chat might have been deleted
        }
        
        
        // Don't sync blank chats or chats with temporary IDs
        if chat.isBlankChat || chat.hasTemporaryId {
            return
        }
        
        // Double-check streaming status right before upload
        if streamingTracker.isStreaming(chatId) {
            return
        }
        
        // Convert to StoredChat and upload
        let storedChat = StoredChat(from: chat, syncVersion: chat.syncVersion + 1)
        try await r2Storage.uploadChat(storedChat)
        
        // Mark as synced
        await markChatAsSynced(chatId, version: storedChat.syncVersion)
        
    }
    
    // MARK: - Bulk Sync Operations
    
    /// Backup all unsynced chats
    func backupUnsyncedChats() async -> SyncResult {
        var result = SyncResult()
        
        do {
            let unsyncedChats = await getUnsyncedChats()
            
            
            // Filter out blank chats, chats with temporary IDs, and streaming chats
            let chatsToSync = unsyncedChats.filter { chat in
                !chat.isBlankChat &&
                !chat.hasTemporaryId &&
                !streamingTracker.isStreaming(chat.id)
            }
            
            
            // Upload all chats in parallel for better performance
            await withTaskGroup(of: (Bool, String?).self) { group in
                for chat in chatsToSync {
                    group.addTask { [weak self] in
                        // Skip if chat started streaming while in queue
                        if self?.streamingTracker.isStreaming(chat.id) ?? false {
                            return (false, nil)
                        }
                        
                        do {
                            let storedChat = StoredChat(from: chat, syncVersion: chat.syncVersion + 1)
                            try await self?.r2Storage.uploadChat(storedChat)
                            await self?.markChatAsSynced(chat.id, version: storedChat.syncVersion)
                            return (true, nil)
                        } catch {
                            return (false, "Failed to backup chat \(chat.id): \(error.localizedDescription)")
                        }
                    }
                }
                
                // Collect results
                for await (success, error) in group {
                    if success {
                        result = SyncResult(
                            uploaded: result.uploaded + 1,
                            downloaded: result.downloaded,
                            errors: result.errors
                        )
                    } else if let error = error {
                        result = SyncResult(
                            uploaded: result.uploaded,
                            downloaded: result.downloaded,
                            errors: result.errors + [error]
                        )
                    }
                }
            }
        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                errors: result.errors + ["Failed to get unsynced chats: \(error.localizedDescription)"]
            )
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
        guard await r2Storage.isAuthenticated() else {
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
            let remoteList = try await r2Storage.listChats(
                limit: pageLimit,
                continuationToken: continuationToken,
                includeContent: true
            )
            
            // Process remote chats in parallel
            var downloadedChats: [StoredChat] = []
            let chatsToProcess = remoteList.conversations
            
            // Initialize encryption once before processing
            _ = try await encryptionService.initialize()
            
            await withTaskGroup(of: StoredChat?.self) { group in
                for remoteChat in chatsToProcess {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        
                        // Skip recently deleted chats
                        if self.deletedChatsTracker.isDeleted(remoteChat.id) {
                            return nil
                        }
                        
                        // Skip invalid chats (blank or without proper ID format)
                        if !(await self.shouldProcessRemoteChat(remoteChat)) {
                            return nil
                        }
                        
                        guard let content = remoteChat.content else {
                            return nil
                        }
                        
                        do {
                            // Parse and decrypt the content
                            guard let contentData = content.data(using: .utf8) else {
                                throw CloudSyncError.invalidBase64
                            }
                            
                            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)
                            
                            // Try to decrypt
                            do {
                                var decryptedChat = try await self.encryptionService.decrypt(encrypted, as: StoredChat.self)
                                
                                // Use dates from metadata for consistency
                                if let createdDate = parseISODate(remoteChat.createdAt) {
                                    decryptedChat.createdAt = createdDate
                                }
                                if let updatedDate = parseISODate(remoteChat.updatedAt) {
                                    decryptedChat.updatedAt = updatedDate
                                }
                                
                                // Set default model if missing (for R2 data)
                                if decryptedChat.modelType == nil {
                                    decryptedChat.modelType = await MainActor.run {
                                        AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
                                    }
                                }
                                
                                return decryptedChat
                            } catch {
                                // Decryption failed - return encrypted placeholder
                                return await self.createEncryptedPlaceholder(
                                    remoteChat: remoteChat,
                                    encryptedContent: content
                                )
                            }
                        } catch {
                            // Failed to parse encrypted data
                            return await self.createEncryptedPlaceholder(
                                remoteChat: remoteChat,
                                encryptedContent: content
                            )
                        }
                    }
                }
                
                // Collect results
                for await chat in group {
                    if let chat = chat {
                        downloadedChats.append(chat)
                    }
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
    
    /// Create encrypted placeholder for chats that failed to decrypt
    private func createEncryptedPlaceholder(
        remoteChat: RemoteChat,
        encryptedContent: String
    ) async -> StoredChat {
        let createdDate = parseISODate(remoteChat.createdAt) ?? Date()
        let updatedDate = parseISODate(remoteChat.updatedAt) ?? Date()
        
        var placeholderChat = StoredChat(
            from: await Chat.create(
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
    
    /// Sync all chats (upload local changes, download remote changes)
    func syncAllChats() async -> SyncResult {
        guard !isSyncing else {
            return SyncResult(errors: ["Sync already in progress"])
        }
        
        isSyncing = true
        syncStatus = "Syncing..."
        defer {
            isSyncing = false
            syncStatus = ""
            lastSyncDate = Date()
        }
        
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
            // Only fetch first page of chats during initial sync to match pagination
            let remoteList = try await r2Storage.listChats(
                limit: Constants.Pagination.chatsPerPage,
                includeContent: true
            )
            
            
            let localChats = await getAllChatsFromStorage()
            
            // Initialize encryption service once before processing
            _ = try await encryptionService.initialize()
            
            // Create maps for easy lookup
            let localChatMap = Dictionary(uniqueKeysWithValues: localChats.map { ($0.id, $0) })
            let remoteConversations = remoteList.conversations
            let remoteChatMap = Dictionary(uniqueKeysWithValues: remoteConversations.map { ($0.id, $0) })
            
            // Process remote chats
            await withTaskGroup(of: (Bool, String?).self) { group in
                for remoteChat in remoteConversations {
                    group.addTask { @MainActor [weak self] in
                        guard let self = self else { return (false, nil) }
                        
                        // First validate if this remote chat should be processed
                        if !self.shouldProcessRemoteChat(remoteChat) {
                            // Clean up invalid chats from cloud
                            self.cleanupInvalidRemoteChat(remoteChat)
                            return (false, nil)
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
                                // Don't overwrite locally modified chats or chats with active streams
                                return (false, nil)
                            }
                            
                            // Also check if chat is currently streaming using the tracker
                            if self.streamingTracker.isStreaming(localChat.id) {
                                return (false, nil)
                            }
                        }
                        
                        let shouldProcess = localChat == nil ||
                            (!remoteTimestamp.isNaN && remoteTimestamp > (localChat?.updatedAt.timeIntervalSince1970 ?? 0)) ||
                            (localChat?.decryptionFailed == true)
                        
                        if shouldProcess, let content = remoteChat.content {
                            do {
                                // Parse and decrypt the content (JSON string format)
                                guard let contentData = content.data(using: .utf8) else {
                                    throw CloudSyncError.invalidBase64
                                }
                                
                                let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)
                                
                                // Try to decrypt the chat data
                                do {
                                    var decryptedChat = try await self.encryptionService.decrypt(encrypted, as: StoredChat.self)
                                    
                                    // Double-check: Even if decryption succeeded, validate the content
                                    if decryptedChat.messages.isEmpty {
                                        // Empty chat that shouldn't be synced
                                        self.cleanupInvalidRemoteChat(remoteChat)
                                        return (false, nil)
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
                                        decryptedChat.modelType = await MainActor.run {
                                            AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
                                        }
                                    }
                                    
                                    await self.saveChatToStorage(decryptedChat)
                                    await self.markChatAsSynced(decryptedChat.id, version: decryptedChat.syncVersion)
                                    return (true, nil)
                                } catch {
                                    // Decryption failed - store as encrypted placeholder for later retry
                                    // Use dates from metadata
                                    let createdDate = parseISODate(remoteChat.createdAt) ?? Date()
                                    let updatedDate = parseISODate(remoteChat.updatedAt) ?? Date()
                                    
                                    // Create placeholder with encrypted data
                                    var placeholderChat = StoredChat(
                                        from: await Chat.create(
                                            id: remoteChat.id,
                                            title: "Encrypted",
                                            messages: [],
                                            createdAt: createdDate
                                        )
                                    )
                                    placeholderChat.decryptionFailed = true
                                    placeholderChat.encryptedData = content
                                    placeholderChat.updatedAt = updatedDate
                                    
                                    await self.saveChatToStorage(placeholderChat)
                                    return (true, nil)
                                }
                            } catch {
                                // Even if we can't parse the encrypted data, store it for later
                                // Extract timestamp from the chat ID to use as createdAt
                                // Format: {reverseTimestamp}_{randomSuffix}
                                let createdDate: Date
                                if let underscoreIndex = remoteChat.id.firstIndex(of: "_"),
                                   let timestamp = Int(remoteChat.id.prefix(upTo: underscoreIndex)) {
                                    // Convert reversed timestamp to actual timestamp
                                    let actualTimestamp = 9999999999999 - timestamp
                                    createdDate = Date(timeIntervalSince1970: Double(actualTimestamp) / 1000.0)
                                } else {
                                    // Fallback to ISO date parsing if ID format is different
                                    createdDate = parseISODate(remoteChat.createdAt) ?? Date()
                                }
                                
                                let updatedDate = parseISODate(remoteChat.updatedAt) ?? Date()
                                
                                var placeholderChat = StoredChat(
                                    from: await Chat.create(
                                        id: remoteChat.id,
                                        title: "Encrypted",
                                        messages: [],
                                        createdAt: createdDate  // Use actual creation time
                                    )
                                )
                                placeholderChat.decryptionFailed = true
                                placeholderChat.encryptedData = content
                                placeholderChat.updatedAt = updatedDate
                                
                                await self.saveChatToStorage(placeholderChat)
                                return (true, nil)  // Don't fail the sync
                            }
                        }
                        
                        return (false, nil)
                    }
                }
                
                // Collect results
                for await (success, error) in group {
                    if success {
                        result = SyncResult(
                            uploaded: result.uploaded,
                            downloaded: result.downloaded + 1,
                            errors: result.errors
                        )
                    } else if let error = error {
                        result = SyncResult(
                            uploaded: result.uploaded,
                            downloaded: result.downloaded,
                            errors: result.errors + [error]
                        )
                    }
                }
            }
            
            // Delete local chats that were deleted remotely (only for first page)
            // Filter for synced chats that aren't blank or temporary
            let sortedSyncedLocalChats = localChats
                .filter { chat in
                    chat.syncedAt != nil && !chat.isBlankChat && !chat.hasTemporaryId
                }
                .sorted { $0.createdAt > $1.createdAt } // Descending (newest first)
            
            let localChatsInFirstPage = Array(sortedSyncedLocalChats.prefix(Constants.Pagination.chatsPerPage))
            
            for localChat in localChatsInFirstPage {
                if !remoteChatMap.keys.contains(localChat.id) {
                    // This chat should be in the first page but isn't in remote - it was deleted
                    await deleteChatFromStorage(localChat.id)
                }
            }
            
        } catch {
            result = SyncResult(
                uploaded: result.uploaded,
                downloaded: result.downloaded,
                errors: result.errors + ["Sync failed: \(error.localizedDescription)"]
            )
        }
        
        syncErrors = result.errors
        return result
    }
    
    // MARK: - Delete Operations
    
    /// Delete a chat from cloud storage
    func deleteFromCloud(_ chatId: String) async throws {
        // Mark as deleted locally first
        deletedChatsTracker.markAsDeleted(chatId)
        
        // Don't attempt deletion if not authenticated
        guard await r2Storage.isAuthenticated() else {
            return
        }
        
        do {
            try await r2Storage.deleteChat(chatId)
            
            // Successfully deleted from cloud, can remove from tracker
            deletedChatsTracker.removeFromDeleted(chatId)
            
        } catch {
            // Silently fail if no auth token set
            if let error = error as? R2StorageError,
               error == .authenticationRequired {
                return
            }
            throw error
        }
    }
    
    // MARK: - Storage Helpers (To be replaced with Core Data)
    
    private func loadChatFromStorage(_ chatId: String) async -> Chat? {
        // TODO: Replace with Core Data query
        let chats = Chat.loadFromDefaults(userId: await getCurrentUserId())
        return chats.first { $0.id == chatId }
    }
    
    private func getAllChatsFromStorage() async -> [Chat] {
        // TODO: Replace with Core Data query
        return Chat.loadFromDefaults(userId: await getCurrentUserId())
    }
    
    private func getUnsyncedChats() async -> [Chat] {
        // TODO: Replace with Core Data query for locallyModified == true
        let allChats = await getAllChatsFromStorage()
        return allChats.filter { chat in
            // Return chats that are locally modified or never synced
            chat.locallyModified || chat.syncedAt == nil
        }
    }
    
    private func saveChatToStorage(_ storedChat: StoredChat) async {
        // TODO: Replace with Core Data save
        let userId = await getCurrentUserId()
        
        var chats = await getAllChatsFromStorage()
        
        // Find existing chat to preserve createdAt if it exists
        let existingChat = chats.first { $0.id == storedChat.id }
        
        // Remove existing chat if present
        chats.removeAll { $0.id == storedChat.id }
        
        // For R2 data without modelType, set it from current config
        var chatToConvert = storedChat
        if chatToConvert.modelType == nil {
            chatToConvert.modelType = await MainActor.run {
                AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }
        }
        
        // Convert to Chat
        var chatToSave = chatToConvert.toChat()
        
        // IMPORTANT: Preserve original createdAt date if chat already exists locally
        // Only update content, not creation timestamp
        if let existingChat = existingChat {
            chatToSave.createdAt = existingChat.createdAt
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
    
    private func deleteChatFromStorage(_ chatId: String) async {
        // TODO: Replace with Core Data delete
        var chats = await getAllChatsFromStorage()
        chats.removeAll { $0.id == chatId }
        
        // Filter out blank chats before saving (matches ChatViewModel.saveChats behavior)
        // BUT keep encrypted chats that failed to decrypt
        let chatsToSave = chats.filter { !$0.messages.isEmpty || $0.decryptionFailed }
        Chat.saveToDefaults(chatsToSave, userId: await getCurrentUserId())
    }
    
    private func getCurrentUserId() async -> String? {
        // Get from Clerk
        if let user = await Clerk.shared.user {
            return user.id
        }
        return nil
    }
    
    // MARK: - Validation Methods
    
    /// Determines if a remote chat should be processed/stored locally
    /// Returns false for blank chats or invalid chats that shouldn't be synced
    private func shouldProcessRemoteChat(_ remoteChat: RemoteChat) -> Bool {
        // Check if it was recently deleted locally
        if deletedChatsTracker.isDeleted(remoteChat.id) {
            return false
        }
        
        // Check if it's a temporary ID (UUID format without underscore)
        if !remoteChat.id.contains("_") {
            return false
        }
        
        // Check metadata for blank chats
        // The API returns messageCount directly as a field
        if let messageCount = remoteChat.messageCount, messageCount == 0 {
            return false
        }
        
        return true
    }
    
    /// Cleans up invalid remote chats that shouldn't exist
    private func cleanupInvalidRemoteChat(_ remoteChat: RemoteChat) {
        Task {
            try? await r2Storage.deleteChat(remoteChat.id)
        }
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
        let total = chatsWithEncryptedData.count
        
        // Process chats in batches to avoid blocking the UI
        for i in stride(from: 0, to: chatsWithEncryptedData.count, by: batchSize) {
            let endIndex = min(i + batchSize, chatsWithEncryptedData.count)
            let batch = Array(chatsWithEncryptedData[i..<endIndex])
            
            // Process batch in parallel
            await withTaskGroup(of: Bool.self) { group in
                for chat in batch {
                    group.addTask { [weak self] in
                        guard let encryptedData = chat.encryptedData else { return false }
                        
                        do {
                            // Parse the stored encrypted data
                            guard let contentData = encryptedData.data(using: .utf8) else {
                                    throw CloudSyncError.invalidBase64
                            }
                            
                            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)
                            
                            // Decrypt the chat data
                            let decryptedData = try await self?.encryptionService.decrypt(encrypted, as: StoredChat.self)
                            
                            guard let decryptedData = decryptedData else { return false }
                            
                            
                            // Create properly decrypted chat with original data, preserving the original ID
                            // Get a model type for decrypted chat (use existing or get default)
                            let modelForChat: ModelType
                            if let existingModel = decryptedData.modelType {
                                modelForChat = existingModel
                            } else {
                                // Get default model from config - if none available, skip this chat
                                let defaultModel = await MainActor.run { 
                                    return AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first 
                                }
                                guard let model = defaultModel else {
                                    return false
                                }
                                modelForChat = model
                            }
                            
                            // Use decrypted content but preserve metadata dates
                            let updatedChat = StoredChat(
                                from: Chat(
                                    id: chat.id,  // Keep original ID (important!)
                                    title: decryptedData.title,
                                    messages: decryptedData.messages,
                                    createdAt: chat.createdAt,  // Preserve metadata date
                                    modelType: modelForChat,
                                    language: decryptedData.language,
                                    userId: decryptedData.userId,
                                    syncVersion: chat.syncVersion,  // Preserve sync metadata
                                    syncedAt: chat.syncedAt,  // Preserve sync metadata
                                    locallyModified: false,  // Reset modification flag
                                    updatedAt: chat.updatedAt,  // Preserve metadata date
                                    decryptionFailed: false,  // Clear the decryption failure flag
                                    encryptedData: nil  // Clear encrypted data
                                )
                            )
                            
                            await self?.saveChatToStorage(updatedChat)
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                
                // Collect results
                for await success in group {
                    if success {
                        decryptedCount += 1
                    }
                }
            }
            
            // Report progress
            onProgress?(min(i + batchSize, total), total)
            
            // Yield to the event loop between batches
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        return decryptedCount
    }
    
    /// Get all chats that have encrypted data stored
    private func getChatsWithEncryptedData() async -> [Chat] {
        let allChats = await getAllChatsFromStorage()
        return allChats.filter { chat in
            chat.decryptionFailed && chat.encryptedData != nil
        }
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
            // Skip blank chats
            if chat.isBlankChat { continue }
            
            // Don't skip any chats when re-encrypting with a new key
            // We want to re-encrypt everything with the new key
            
            do {
                // Re-encrypt the chat with the new key by forcing a sync
                guard await r2Storage.isAuthenticated() else { continue }
                
                // Increment sync version to force upload
                var chatToReencrypt = chat
                chatToReencrypt.syncVersion = chat.syncVersion + 1
                chatToReencrypt.locallyModified = true
                
                // Save locally with new sync version
                await saveChatToStorage(StoredChat(from: chatToReencrypt))
                
                // Upload to cloud (will be encrypted with new key)
                let storedChat = StoredChat(from: chatToReencrypt)
                try await r2Storage.uploadChat(storedChat)
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

