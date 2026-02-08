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
    var createdAt: Date      // Will be encoded as ISO string for API
    var updatedAt: Date      // Will be encoded as ISO string for API
    var modelType: ModelType?  // Not synced - local UI preference only
    var language: String?
    var userId: String?
    
    // Sync metadata
    var syncVersion: Int
    var syncedAt: Date?      // Will be encoded as timestamp in milliseconds
    var locallyModified: Bool
    
    // For handling encrypted chats that failed to decrypt
    var decryptionFailed: Bool?
    var encryptedData: String?
    
    // Project association (used by React, preserved by iOS)
    var projectId: String?

    // For tracking streaming state
    var hasActiveStream: Bool?
    
    init(from chat: Chat, syncVersion: Int = 0) {
        self.id = chat.id
        self.title = chat.title
        self.messages = chat.messages
        self.createdAt = chat.createdAt
        self.updatedAt = chat.updatedAt
        self.modelType = chat.modelType
        self.language = chat.language
        self.userId = chat.userId
        self.syncVersion = syncVersion
        self.syncedAt = nil
        self.locallyModified = true
        self.projectId = chat.projectId
        self.hasActiveStream = chat.hasActiveStream
    }
    
    @MainActor
    func toChat() -> Chat? {
        // Use existing modelType, or fall back to current/first available model
        let model: ModelType
        if let existingModel = modelType {
            model = existingModel
        } else if let currentModel = AppConfig.shared.currentModel {
            model = currentModel
        } else if let firstModel = AppConfig.shared.availableModels.first {
            model = firstModel
        } else {
            return nil
        }

        var chat = Chat(
            id: id,
            title: title,
            messages: messages,
            createdAt: createdAt,
            modelType: model,
            language: language,
            userId: userId,
            syncVersion: syncVersion,
            syncedAt: syncedAt,
            locallyModified: locallyModified,
            updatedAt: updatedAt,
            decryptionFailed: decryptionFailed ?? false,
            encryptedData: encryptedData,
            projectId: projectId
        )

        if let hasActiveStream = hasActiveStream {
            chat.hasActiveStream = hasActiveStream
        }

        return chat
    }
    
    // Custom encoding for cross-platform compatibility
    enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt
        case language, userId
        case syncVersion, syncedAt, locallyModified
        case decryptionFailed, encryptedData, projectId, hasActiveStream
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)

        // Dates as ISO strings with fractional seconds (matching JavaScript's toISOString())
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(isoFormatter.string(from: createdAt), forKey: .createdAt)
        try container.encode(isoFormatter.string(from: updatedAt), forKey: .updatedAt)

        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(userId, forKey: .userId)

        try container.encode(syncVersion, forKey: .syncVersion)

        // syncedAt as milliseconds timestamp if present
        if let syncedAt = syncedAt {
            try container.encode(Int(syncedAt.timeIntervalSince1970 * 1000), forKey: .syncedAt)
        }

        try container.encode(locallyModified, forKey: .locallyModified)
        try container.encodeIfPresent(decryptionFailed, forKey: .decryptionFailed)
        try container.encodeIfPresent(encryptedData, forKey: .encryptedData)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(hasActiveStream, forKey: .hasActiveStream)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        
        // Dates from ISO strings - configure formatter to handle fractional seconds
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // Also create a fallback formatter without fractional seconds
        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]
        
        let createdAtString = try container.decode(String.self, forKey: .createdAt)
        let updatedAtString = try container.decode(String.self, forKey: .updatedAt)
        
        // Try parsing with fractional seconds first, then without, before falling back
        if let date = isoFormatter.date(from: createdAtString) {
            createdAt = date
        } else if let date = isoFormatterNoFraction.date(from: createdAtString) {
            createdAt = date
        } else {
            createdAt = Date()
        }
        
        if let date = isoFormatter.date(from: updatedAtString) {
            updatedAt = date
        } else if let date = isoFormatterNoFraction.date(from: updatedAtString) {
            updatedAt = date
        } else {
            updatedAt = Date()
        }
        
        // modelType is not synced - it's a local UI preference
        modelType = nil
        language = try container.decodeIfPresent(String.self, forKey: .language)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        
        // syncVersion may not exist in older data
        syncVersion = try container.decodeIfPresent(Int.self, forKey: .syncVersion) ?? 0
        
        // syncedAt from milliseconds timestamp if present
        if let syncedAtMs = try container.decodeIfPresent(Int.self, forKey: .syncedAt) {
            syncedAt = Date(timeIntervalSince1970: Double(syncedAtMs) / 1000.0)
        } else {
            syncedAt = nil
        }
        
        locallyModified = try container.decodeIfPresent(Bool.self, forKey: .locallyModified) ?? false
        decryptionFailed = try container.decodeIfPresent(Bool.self, forKey: .decryptionFailed)
        encryptedData = try container.decodeIfPresent(String.self, forKey: .encryptedData)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        hasActiveStream = try container.decodeIfPresent(Bool.self, forKey: .hasActiveStream)
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

/// Response from deleted-since API
struct DeletedChatsResponse: Codable {
    let deletedIds: [String]
}

/// Remote chat metadata from API
struct RemoteChat: Codable {
    let id: String
    let key: String
    let createdAt: String
    let updatedAt: String
    let title: String?  // Optional - encrypted chats don't have readable titles
    let messageCount: Int?  // Optional - might not be present
    let syncVersion: Int?  // Optional - for version tracking
    let size: Int?  // Optional - file size
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
    let projectId: String?
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

/// Profile upload response
struct ProfileUploadResponse: Codable {
    let version: Int
    let message: String?
}

// MARK: - Sync Status Models

/// Chat sync status from server (for efficient sync checking)
struct ChatSyncStatus: Codable {
    let count: Int
    let lastUpdated: String?
}

/// Profile sync status from server (for efficient sync checking)
struct ProfileSyncStatus: Codable {
    let exists: Bool
    let version: Int?
    let lastUpdated: String?
}

/// Result of sync status check
struct SyncStatusResult {
    let needsSync: Bool
    let reason: SyncStatusReason
    let remoteCount: Int?
    let remoteLastUpdated: String?
}

/// Reason for needing or not needing sync
enum SyncStatusReason {
    case noChanges
    case countChanged
    case updated
    case localChanges
    case error
}

// MARK: - Sync State Models

/// Tracks deleted chats to prevent resurrection during sync
@MainActor
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
        // Create a copy of the dictionary to iterate over to avoid mutation during enumeration
        let deletionTimesCopy = deletionTimes
        for (chatId, deletionTime) in deletionTimesCopy {
            if now.timeIntervalSince(deletionTime) > expirationTime {
                deletedChats.remove(chatId)
                deletionTimes.removeValue(forKey: chatId)
            }
        }
    }
}

/// Tracks chats that are currently streaming to prevent sync conflicts
@MainActor
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