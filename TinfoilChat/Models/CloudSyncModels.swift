//
//  CloudSyncModels.swift
//  TinfoilChat
//
//  Models for cloud synchronization
//

import Foundation

// MARK: - Sync Models

/// Extended chat model with sync metadata
struct StoredChat: Codable {
    let id: String
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date
    var modelType: ModelType
    var language: String?
    var userId: String?
    
    // Sync metadata
    var syncVersion: Int
    var syncedAt: Date?
    var locallyModified: Bool
    
    // For handling encrypted chats that failed to decrypt
    var decryptionFailed: Bool?
    var dataCorrupted: Bool?
    var encryptedData: String?
    
    // For tracking streaming state
    var hasActiveStream: Bool?
    
    init(from chat: Chat, syncVersion: Int = 0) {
        self.id = chat.id
        self.title = chat.title
        self.messages = chat.messages
        self.createdAt = chat.createdAt
        self.updatedAt = chat.createdAt
        self.lastAccessedAt = Date()
        self.modelType = chat.modelType
        self.language = chat.language
        self.userId = chat.userId
        self.syncVersion = syncVersion
        self.syncedAt = nil
        self.locallyModified = true
        self.hasActiveStream = chat.hasActiveStream
    }
    
    func toChat() -> Chat {
        return Chat(
            id: id,
            title: title,
            messages: messages,
            createdAt: createdAt,
            modelType: modelType,
            language: language,
            userId: userId
        )
    }
}

/// Result of a sync operation
struct SyncResult {
    let uploaded: Int
    let downloaded: Int
    let errors: [String]
    
    init(uploaded: Int = 0, downloaded: Int = 0, errors: [String] = []) {
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.errors = errors
    }
}

/// Result of paginated chat loading
struct PaginatedChatsResult {
    let chats: [StoredChat]
    let hasMore: Bool
    let nextToken: String?
    
    init(chats: [StoredChat], hasMore: Bool = false, nextToken: String? = nil) {
        self.chats = chats
        self.hasMore = hasMore
        self.nextToken = nextToken
    }
}

// MARK: - API Response Models

/// Response from chat list API
struct ChatListResponse: Codable {
    let conversations: [RemoteChat]
    let nextContinuationToken: String?
    let hasMore: Bool
}

/// Remote chat metadata from API
struct RemoteChat: Codable {
    let id: String
    let key: String
    let createdAt: String
    let updatedAt: String
    let title: String
    let messageCount: Int
    let size: Int
    let content: String?  // Encrypted chat content (optional in list)
}

/// Request for generating conversation ID
struct GenerateConversationIdRequest: Codable {
    let timestamp: String?
}

/// Response from conversation ID generation
struct GenerateConversationIdResponse: Codable {
    let conversationId: String
    let timestamp: String
    let reverseTimestamp: Int
}

/// Request for uploading a conversation
struct UploadConversationRequest: Codable {
    let conversationId: String
    let data: String  // JSON stringified encrypted data
    let metadata: [String: String]
}

/// Request for updating metadata
struct UpdateMetadataRequest: Codable {
    let conversationId: String
    let metadata: [String: String]
}

// MARK: - Profile Sync Models

/// Profile data structure matching React implementation
struct ProfileData: Codable {
    // Theme settings
    var isDarkMode: Bool?
    
    // Chat settings
    var maxPromptMessages: Int?
    var language: String?
    
    // Personalization settings
    var nickname: String?
    var profession: String?
    var traits: [String]?
    var additionalContext: String?
    var isUsingPersonalization: Bool?
    
    // Custom system prompt settings
    var isUsingCustomPrompt: Bool?
    var customSystemPrompt: String?
    
    // Metadata
    var version: Int?
    var updatedAt: String?
}

/// Profile API response
struct ProfileResponse: Codable {
    let data: String  // Encrypted profile data
    let version: String?
    let created: String?
    let updated: String?
}

/// Profile upload request
struct ProfileUploadRequest: Codable {
    let data: String  // JSON stringified encrypted data
}

// MARK: - Sync State Models

/// Tracks deleted chats to prevent resurrection during sync
class DeletedChatsTracker {
    static let shared = DeletedChatsTracker()
    
    private var deletedChats: Set<String> = []
    private var deletionTimes: [String: Date] = [:]
    private let expirationTime: TimeInterval = 300 // 5 minutes
    
    private init() {}
    
    /// Mark a chat as deleted
    func markAsDeleted(_ chatId: String) {
        deletedChats.insert(chatId)
        deletionTimes[chatId] = Date()
        
        // Schedule cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + expirationTime) { [weak self] in
            self?.cleanupExpired()
        }
    }
    
    /// Check if a chat was recently deleted
    func isDeleted(_ chatId: String) -> Bool {
        cleanupExpired()
        return deletedChats.contains(chatId)
    }
    
    /// Remove from deleted tracking (e.g., after successful cloud deletion)
    func removeFromDeleted(_ chatId: String) {
        deletedChats.remove(chatId)
        deletionTimes.removeValue(forKey: chatId)
    }
    
    private func cleanupExpired() {
        let now = Date()
        for (chatId, deletionTime) in deletionTimes {
            if now.timeIntervalSince(deletionTime) > expirationTime {
                deletedChats.remove(chatId)
                deletionTimes.removeValue(forKey: chatId)
            }
        }
    }
}

/// Tracks chats that are currently streaming to prevent sync conflicts
class StreamingTracker {
    static let shared = StreamingTracker()
    
    private var streamingChats: Set<String> = []
    private var streamEndCallbacks: [String: [() -> Void]] = [:]
    
    private init() {}
    
    /// Mark chat as streaming
    func startStreaming(_ chatId: String) {
        streamingChats.insert(chatId)
    }
    
    /// Mark chat as finished streaming
    func endStreaming(_ chatId: String) {
        streamingChats.remove(chatId)
        
        // Execute any callbacks waiting for this chat to finish streaming
        if let callbacks = streamEndCallbacks[chatId] {
            for callback in callbacks {
                callback()
            }
            streamEndCallbacks.removeValue(forKey: chatId)
        }
    }
    
    /// Check if chat is currently streaming
    func isStreaming(_ chatId: String) -> Bool {
        return streamingChats.contains(chatId)
    }
    
    /// Get all streaming chat IDs
    func getStreamingChats() -> [String] {
        return Array(streamingChats)
    }
    
    /// Register a callback to be called when a specific chat finishes streaming
    func onStreamEnd(_ chatId: String, callback: @escaping () -> Void) {
        if !isStreaming(chatId) {
            // Chat is not streaming, execute callback immediately
            callback()
            return
        }
        
        if streamEndCallbacks[chatId] == nil {
            streamEndCallbacks[chatId] = []
        }
        streamEndCallbacks[chatId]?.append(callback)
    }
}