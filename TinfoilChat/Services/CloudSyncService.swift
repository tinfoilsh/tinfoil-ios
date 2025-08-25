//
//  CloudSyncService.swift
//  TinfoilChat
//
//  Main service for orchestrating cloud synchronization
//

import Foundation
import Combine
import Clerk

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
    private let CHATS_PER_PAGE = 50  // Match React's PAGINATION.CHATS_PER_PAGE
    
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
                limit: CHATS_PER_PAGE,
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
                    group.addTask { [weak self] in
                        // Skip if this chat was recently deleted
                        if self?.deletedChatsTracker.isDeleted(remoteChat.id) ?? false {
                            return (false, nil)
                        }
                        
                        let localChat = localChatMap[remoteChat.id]
                        
                        // Process if:
                        // 1. Chat doesn't exist locally
                        // 2. Remote is newer (based on updatedAt > syncedAt)
                        // 3. Chat failed decryption (to retry with new key)
                        let remoteTimestamp = ISO8601DateFormatter().date(from: remoteChat.updatedAt)?.timeIntervalSince1970 ?? 0
                        let shouldProcess = localChat == nil ||
                            (!remoteTimestamp.isNaN && remoteTimestamp > (localChat?.syncedAt?.timeIntervalSince1970 ?? 0)) ||
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
                                    let decryptedChat = try await self?.encryptionService.decrypt(encrypted, as: StoredChat.self)
                                    
                                    if let decryptedChat = decryptedChat {
                                        // Save to local storage (skip blank chats)
                                        // For R2 data, ensure modelType is set
                                        var chatToCheck = decryptedChat
                                        if chatToCheck.modelType == nil {
                                            chatToCheck.modelType = await MainActor.run {
                                                AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
                                            }
                                        }
                                        if !chatToCheck.toChat().isBlankChat {
                                            await self?.saveChatToStorage(decryptedChat)
                                            await self?.markChatAsSynced(decryptedChat.id, version: decryptedChat.syncVersion)
                                            return (true, nil)
                                        }
                                        return (false, nil)
                                    }
                                } catch {
                                    // If decryption fails, store the encrypted data for later retry
                                    
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
                                        let isoFormatter = ISO8601DateFormatter()
                                        createdDate = isoFormatter.date(from: remoteChat.createdAt) ?? Date()
                                    }
                                    
                                    let isoFormatter = ISO8601DateFormatter()
                                    let updatedDate = isoFormatter.date(from: remoteChat.updatedAt) ?? Date()
                                    
                                    // Create placeholder with encrypted data
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
                                    
                                    await self?.saveChatToStorage(placeholderChat)
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
                                    let isoFormatter = ISO8601DateFormatter()
                                    createdDate = isoFormatter.date(from: remoteChat.createdAt) ?? Date()
                                }
                                
                                let isoFormatter = ISO8601DateFormatter()
                                let updatedDate = isoFormatter.date(from: remoteChat.updatedAt) ?? Date()
                                
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
                                
                                await self?.saveChatToStorage(placeholderChat)
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
            
            let localChatsInFirstPage = Array(sortedSyncedLocalChats.prefix(CHATS_PER_PAGE))
            
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
    
    // MARK: - Pagination Support
    
    /// Load chats with pagination - combines local and remote chats
    func loadChatsWithPagination(limit: Int, continuationToken: String? = nil, loadLocal: Bool = true) async -> PaginatedChatsResult {
        // If no authentication, just return local chats
        guard await r2Storage.isAuthenticated() else {
            if loadLocal {
                let localChats = await getAllChatsFromStorage()
                let sortedChats = localChats.sorted { $0.createdAt > $1.createdAt }
                
                let start = continuationToken.flatMap { Int($0) } ?? 0
                let paginatedChats = Array(sortedChats.dropFirst(start).prefix(limit))
                
                return PaginatedChatsResult(
                    chats: paginatedChats.map { StoredChat(from: $0) },
                    hasMore: start + limit < sortedChats.count,
                    nextToken: start + limit < sortedChats.count ? String(start + limit) : nil
                )
            }
            return PaginatedChatsResult(chats: [])
        }
        
        do {
            // Initialize encryption service once before processing
            _ = try await encryptionService.initialize()
            
            // For authenticated users, load from R2 with content
            let remoteList = try await r2Storage.listChats(
                limit: limit,
                continuationToken: continuationToken,
                includeContent: true
            )
            
            // Process the chat data from each remote chat in parallel
            var downloadedChats: [StoredChat] = []
            
            await withTaskGroup(of: StoredChat?.self) { group in
                for remoteChat in remoteList.conversations {
                    group.addTask { [weak self] in
                        // Skip if this chat was recently deleted
                        if self?.deletedChatsTracker.isDeleted(remoteChat.id) ?? false {
                            return nil
                        }
                        
                        guard let content = remoteChat.content else { return nil }
                        
                        do {
                            // Parse content (JSON string format)
                            guard let contentData = content.data(using: .utf8) else {
                                throw CloudSyncError.invalidBase64
                            }
                            
                            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: contentData)
                            
                            // Try to decrypt the chat data
                            do {
                                return try await self?.encryptionService.decrypt(encrypted, as: StoredChat.self)
                            } catch {
                                // If decryption fails, return placeholder with proper dates
                                // Extract timestamp from the chat ID (format: {reverseTimestamp}_{randomSuffix})
                                let createdDate: Date
                                if let underscoreIndex = remoteChat.id.firstIndex(of: "_"),
                                   let timestamp = Int(remoteChat.id.prefix(upTo: underscoreIndex)) {
                                    // Convert reversed timestamp to actual timestamp
                                    let actualTimestamp = 9999999999999 - timestamp
                                    createdDate = Date(timeIntervalSince1970: Double(actualTimestamp) / 1000.0)
                                } else {
                                    // Fallback to ISO date parsing if ID format is different
                                    let isoFormatter = ISO8601DateFormatter()
                                    createdDate = isoFormatter.date(from: remoteChat.createdAt) ?? Date()
                                }
                                
                                let isoFormatter = ISO8601DateFormatter()
                                let updatedDate = isoFormatter.date(from: remoteChat.updatedAt) ?? Date()
                                
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
                                return placeholderChat
                            }
                        } catch {
                            return nil
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
            
            return PaginatedChatsResult(
                chats: downloadedChats,
                hasMore: remoteList.hasMore,
                nextToken: remoteList.nextContinuationToken
            )
            
        } catch {
            
            // Fall back to local chats if remote loading fails
            if loadLocal {
                let localChats = await getAllChatsFromStorage()
                let sortedChats = localChats.sorted { $0.createdAt > $1.createdAt }
                
                let start = continuationToken.flatMap { Int($0) } ?? 0
                let paginatedChats = Array(sortedChats.dropFirst(start).prefix(limit))
                
                return PaginatedChatsResult(
                    chats: paginatedChats.map { StoredChat(from: $0) },
                    hasMore: start + limit < sortedChats.count,
                    nextToken: start + limit < sortedChats.count ? String(start + limit) : nil
                )
            }
            
            return PaginatedChatsResult(chats: [], hasMore: false)
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
        
        // Save back to defaults
        Chat.saveToDefaults(chats, userId: userId)
    }
    
    private func markChatAsSynced(_ chatId: String, version: Int) async {
        var chats = await getAllChatsFromStorage()
        
        if let index = chats.firstIndex(where: { $0.id == chatId }) {
            chats[index].syncVersion = version
            chats[index].syncedAt = Date()
            chats[index].locallyModified = false
            
            Chat.saveToDefaults(chats, userId: await getCurrentUserId())
        }
    }
    
    private func deleteChatFromStorage(_ chatId: String) async {
        // TODO: Replace with Core Data delete
        var chats = await getAllChatsFromStorage()
        chats.removeAll { $0.id == chatId }
        Chat.saveToDefaults(chats, userId: await getCurrentUserId())
    }
    
    private func getCurrentUserId() async -> String? {
        // Get from Clerk
        if let user = await Clerk.shared.user {
            return user.id
        }
        return nil
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
                            
                            // Match React: use ALL decrypted data fields, only override specific metadata
                            let updatedChat = StoredChat(
                                from: Chat(
                                    id: chat.id,  // Keep original ID (important!)
                                    title: decryptedData.title,
                                    messages: decryptedData.messages,
                                    createdAt: decryptedData.createdAt,  // Use decrypted data's date
                                    modelType: modelForChat,
                                    language: decryptedData.language,
                                    userId: decryptedData.userId,
                                    syncVersion: chat.syncVersion,  // Preserve sync metadata
                                    syncedAt: chat.syncedAt,  // Preserve sync metadata
                                    locallyModified: false,  // Reset modification flag
                                    updatedAt: decryptedData.updatedAt,  // Use decrypted data's date
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
            
            // Skip chats that failed to decrypt
            if chat.decryptionFailed {
                continue
            }
            
            // Skip chats that still have encrypted data
            if chat.encryptedData != nil {
                continue
            }
            
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

