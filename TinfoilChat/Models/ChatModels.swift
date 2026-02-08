//
//  ChatModels.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import Foundation
import UIKit
import Clerk

/// Represents a chat conversation
struct Chat: Identifiable, Codable {
    enum TitleState: String, Codable {
        case placeholder
        case generated
        case manual
    }

    static let placeholderTitle = "New Chat"

    let id: String
    var title: String
    var titleState: TitleState
    var messages: [Message]
    var hasActiveStream: Bool = false
    var createdAt: Date
    var modelType: ModelType
    var language: String?
    var userId: String?
    
    // Sync metadata
    var syncVersion: Int = 0
    var syncedAt: Date?
    var locallyModified: Bool = true
    var updatedAt: Date
    
    // For handling encrypted chats that failed to decrypt
    var decryptionFailed: Bool = false
    var dataCorrupted: Bool = false
    var encryptedData: String?

    // Project association (used by React, preserved by iOS)
    var projectId: String?

    // Computed properties for sync filtering
    var isBlankChat: Bool {
        // Don't treat failed-to-decrypt chats as blank
        return messages.isEmpty && !decryptionFailed
    }
    
    var needsGeneratedTitle: Bool {
        return titleState == .placeholder
    }

    /// Generates a permanent reverse-timestamp ID locally (matching the web app format).
    /// Format: {reverseTimestamp padded to 13 digits}_{UUID}
    static func generateReverseId(timestampMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> String {
        let reverseTimestamp = Constants.Sync.maxReverseTimestamp - timestampMs
        let reverseTsStr = String(format: "%0\(Constants.Sync.reverseTimestampDigits)d", reverseTimestamp)
        return "\(reverseTsStr)_\(UUID().uuidString)"
    }

    static func deriveTitleState(for title: String, messages: [Message]) -> TitleState {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if messages.isEmpty {
            return normalizedTitle.isEmpty || normalizedTitle == placeholderTitle ? .placeholder : .manual
        }
        if normalizedTitle.isEmpty || normalizedTitle == placeholderTitle {
            return .placeholder
        }
        return .generated
    }

    init(
        id: String = Chat.generateReverseId(),
        title: String = Chat.placeholderTitle,
        titleState: TitleState? = nil,
        messages: [Message] = [], 
        createdAt: Date = Date(),
        modelType: ModelType,
        language: String? = nil,
        userId: String? = nil,
        syncVersion: Int = 0,
        syncedAt: Date? = nil,
        locallyModified: Bool = true,
        updatedAt: Date? = nil,
        decryptionFailed: Bool = false,
        dataCorrupted: Bool = false,
        encryptedData: String? = nil,
        projectId: String? = nil)
    {
        let resolvedTitleState = titleState ?? Chat.deriveTitleState(for: title, messages: messages)

        self.id = id
        self.title = title
        self.titleState = resolvedTitleState
        self.messages = messages
        self.createdAt = createdAt
        self.modelType = modelType
        self.language = language
        self.userId = userId
        self.syncVersion = syncVersion
        self.syncedAt = syncedAt
        self.locallyModified = locallyModified
        self.updatedAt = updatedAt ?? createdAt
        self.decryptionFailed = decryptionFailed
        self.dataCorrupted = dataCorrupted
        self.encryptedData = encryptedData
        self.projectId = projectId
    }
    
    // MARK: - Factory Methods

    /// Creates a new chat with the current model from AppConfig
    @MainActor
    static func create(
        id: String = Chat.generateReverseId(),
        title: String = Chat.placeholderTitle,
        titleState: TitleState? = nil,
        messages: [Message] = [],
        createdAt: Date = Date(),
        modelType: ModelType? = nil,
        language: String? = nil,
        userId: String? = nil,
        syncVersion: Int = 0,
        syncedAt: Date? = nil,
        locallyModified: Bool = true,
        updatedAt: Date? = nil
    ) -> Chat {
        // Try to use the provided model, fall back to current model, then first available
        guard let model = modelType ?? AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first else {
            fatalError("Cannot create Chat without available models. Ensure AppConfig is initialized before creating chats.")
        }
        return Chat(
            id: id,
            title: title,
            titleState: titleState,
            messages: messages,
            createdAt: createdAt,
            modelType: model,
            language: language,
            userId: userId,
            syncVersion: syncVersion,
            syncedAt: syncedAt,
            locallyModified: locallyModified,
            updatedAt: updatedAt
        )
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, title, titleState, messages, hasActiveStream, createdAt, modelType, language, userId
        case syncVersion, syncedAt, locallyModified, updatedAt
        case decryptionFailed, dataCorrupted, encryptedData, projectId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        titleState = (try? container.decode(TitleState.self, forKey: .titleState)) ?? Chat.deriveTitleState(for: title, messages: messages)
        hasActiveStream = try container.decodeIfPresent(Bool.self, forKey: .hasActiveStream) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modelType = try container.decode(ModelType.self, forKey: .modelType)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        
        // Sync metadata
        syncVersion = try container.decodeIfPresent(Int.self, forKey: .syncVersion) ?? 0
        syncedAt = try container.decodeIfPresent(Date.self, forKey: .syncedAt)
        locallyModified = try container.decodeIfPresent(Bool.self, forKey: .locallyModified) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        
        // Encryption fields
        decryptionFailed = try container.decodeIfPresent(Bool.self, forKey: .decryptionFailed) ?? false
        dataCorrupted = try container.decodeIfPresent(Bool.self, forKey: .dataCorrupted) ?? false
        encryptedData = try container.decodeIfPresent(String.self, forKey: .encryptedData)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(titleState, forKey: .titleState)
        try container.encode(messages, forKey: .messages)
        try container.encode(hasActiveStream, forKey: .hasActiveStream)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modelType, forKey: .modelType)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(userId, forKey: .userId)
        
        // Sync metadata
        try container.encode(syncVersion, forKey: .syncVersion)
        try container.encodeIfPresent(syncedAt, forKey: .syncedAt)
        try container.encode(locallyModified, forKey: .locallyModified)
        try container.encode(updatedAt, forKey: .updatedAt)
        
        // Encryption fields
        try container.encode(decryptionFailed, forKey: .decryptionFailed)
        try container.encode(dataCorrupted, forKey: .dataCorrupted)
        try container.encodeIfPresent(encryptedData, forKey: .encryptedData)
        try container.encodeIfPresent(projectId, forKey: .projectId)
    }
    
    // MARK: - Haptic Feedback Methods

    /// Triggers haptic feedback when a chat operation succeeds
    static func triggerSuccessFeedback() {
        HapticFeedback.trigger(.success)
    }

    // MARK: - Secure Storage Methods
    
    static func saveToDefaults(_ chats: [Chat], userId: String?) {
        do {
            let userIdKey = userId ?? "anonymous"
            try KeychainChatStorage.shared.saveChats(chats, userId: userIdKey)
        } catch {
            #if DEBUG
            print("Failed to save chats to Keychain: \(error)")
            #endif
        }
    }
    
    static func loadFromDefaults(userId: String?) -> [Chat] {
        let userIdKey = userId ?? "anonymous"
        
        // Load from Keychain - migration to cloud is handled separately by CloudMigrationService
        if let chats = KeychainChatStorage.shared.loadChats(userId: userIdKey) {
            return chats.sorted { $0.createdAt > $1.createdAt }
        }
        
        return []
    }
    
    // MARK: - Per-Chat File Storage Methods

    static func saveChat(_ chat: Chat, userId: String?) async {
        guard let userId = userId else { return }
        do {
            try await EncryptedFileStorage.shared.saveChat(chat, userId: userId)
        } catch {
            #if DEBUG
            print("Failed to save chat to file storage: \(error)")
            #endif
        }
    }

    static func loadChatIndex(userId: String?) async -> [ChatIndexEntry] {
        guard let userId = userId else { return [] }
        return (try? await EncryptedFileStorage.shared.loadIndex(userId: userId)) ?? []
    }

    static func loadChat(chatId: String, userId: String?) async -> Chat? {
        guard let userId = userId else { return nil }
        return try? await EncryptedFileStorage.shared.loadChat(chatId: chatId, userId: userId)
    }

    static func loadChats(chatIds: [String], userId: String?) async -> [Chat] {
        guard let userId = userId else { return [] }
        return (try? await EncryptedFileStorage.shared.loadChats(chatIds: chatIds, userId: userId)) ?? []
    }

    static func deleteChatFromStorage(chatId: String, userId: String?) async {
        guard let userId = userId else { return }
        try? await EncryptedFileStorage.shared.deleteChat(chatId: chatId, userId: userId)
    }

    static func deleteAllChatsFromStorage(userId: String?) async {
        guard let userId = userId else { return }
        try? EncryptedFileStorage.shared.deleteAllChats(userId: userId)
    }

    // MARK: - Title Generation handled via LLM (see ChatViewModel.generateLLMTitle)
}

/// Represents a message role
enum MessageRole: String, Codable {
    case user
    case assistant
}

// MARK: - Web Search Types

/// Represents a source from web search results
struct WebSearchSource: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let url: String

    init(id: String = UUID().uuidString, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Generate UUID if id is missing (React app doesn't include it)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
    }
}

/// Status of a web search operation
enum WebSearchStatus: String, Codable, Equatable {
    case searching
    case completed
    case failed
    case blocked
}

/// State of web search for a message
struct WebSearchState: Codable, Equatable {
    var query: String?
    var status: WebSearchStatus
    var sources: [WebSearchSource]
    var reason: String?

    init(
        query: String? = nil,
        status: WebSearchStatus = .searching,
        sources: [WebSearchSource] = [],
        reason: String? = nil
    ) {
        self.query = query
        self.status = status
        self.sources = sources
        self.reason = reason
    }
}

/// URL citation from web search results, matching React's Annotation type
struct URLCitation: Codable, Equatable {
    let title: String
    let url: String
    let start_index: Int?
    let end_index: Int?
}

/// Annotation wrapper, matching React's { type: 'url_citation', url_citation: URLCitation }
struct Annotation: Codable, Equatable {
    let type: String
    let url_citation: URLCitation
}

/// Document name reference, matching React's { name: string }
struct DocumentName: Codable, Equatable {
    let name: String
}

/// Image data for multimodal support, matching React's { base64: string; mimeType: string }
struct ImageData: Codable, Equatable {
    let base64: String
    let mimeType: String
}

/// Represents a single message in a chat
struct Message: Identifiable, Codable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    var thoughts: String? = nil
    var isThinking: Bool = false
    var timestamp: Date
    var isCollapsed: Bool = true
    var isStreaming: Bool = false
    var streamError: String? = nil
    var generationTimeSeconds: Double? = nil
    var contentChunks: [ContentChunk] = []
    var webSearchState: WebSearchState? = nil
    var attachments: [Attachment] = []
    var documentContent: String? = nil
    var imageData: [ImageData]? = nil

    // Passthrough fields for cross-platform round-trip (used by React, preserved by iOS)
    var thinkingDuration: Double? = nil
    var isError: Bool? = nil
    var multimodalText: String? = nil
    var documents: [DocumentName]? = nil
    var webSearchBeforeThinking: Bool? = nil
    var annotations: [Annotation]? = nil
    var searchReasoning: String? = nil

    static let longMessageAttachmentThreshold = 1200
    var shouldDisplayAsAttachment: Bool {
        role == .user && content.count >= Message.longMessageAttachmentThreshold
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private static let iso8601FormatterNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    init(id: String = UUID().uuidString, role: MessageRole, content: String, thoughts: String? = nil, isThinking: Bool = false, timestamp: Date = Date(), isCollapsed: Bool = true, generationTimeSeconds: Double? = nil, contentChunks: [ContentChunk] = [], webSearchState: WebSearchState? = nil, attachments: [Attachment] = [], documentContent: String? = nil, imageData: [ImageData]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thoughts = thoughts
        self.isThinking = isThinking
        self.timestamp = timestamp
        self.isCollapsed = isCollapsed
        self.generationTimeSeconds = generationTimeSeconds
        self.contentChunks = contentChunks
        self.webSearchState = webSearchState
        self.attachments = attachments
        self.documentContent = documentContent
        self.imageData = imageData
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, role, content, thoughts, isThinking, timestamp, isCollapsed, isStreaming, streamError, generationTimeSeconds, contentChunks, webSearchState
        case webSearch // Alternative key used by React app
        case attachments, documentContent, imageData
        case imageBase64 // Legacy iOS key for backward compatibility
        case thinkingDuration, isError, multimodalText, documents
        case webSearchBeforeThinking, annotations, searchReasoning
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Make id optional for cross-platform compatibility with React
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        thoughts = try container.decodeIfPresent(String.self, forKey: .thoughts)
        isThinking = try container.decodeIfPresent(Bool.self, forKey: .isThinking) ?? false
        
        // Handle timestamp as either Date or String (ISO8601) for cross-platform compatibility
        if let date = try? container.decode(Date.self, forKey: .timestamp) {
            timestamp = date
        } else if let dateString = try? container.decode(String.self, forKey: .timestamp) {
            // Try parsing with fractional seconds first, then without
            timestamp = Self.iso8601Formatter.date(from: dateString) 
                ?? Self.iso8601FormatterNoFractional.date(from: dateString)
                ?? Date()
        } else {
            timestamp = Date()
        }
        
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? true
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        streamError = try container.decodeIfPresent(String.self, forKey: .streamError)
        generationTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .generationTimeSeconds)
        contentChunks = try container.decodeIfPresent([ContentChunk].self, forKey: .contentChunks) ?? []
        // Try iOS key first, then React key for cross-platform compatibility
        webSearchState = try container.decodeIfPresent(WebSearchState.self, forKey: .webSearchState)
            ?? container.decodeIfPresent(WebSearchState.self, forKey: .webSearch)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        documentContent = try container.decodeIfPresent(String.self, forKey: .documentContent)
        // Try React's imageData array first, fall back to legacy iOS imageBase64 string
        if let data = try container.decodeIfPresent([ImageData].self, forKey: .imageData) {
            imageData = data
        } else if let legacyBase64 = try container.decodeIfPresent(String.self, forKey: .imageBase64) {
            imageData = [ImageData(base64: legacyBase64, mimeType: Constants.Attachments.defaultImageMimeType)]
        } else {
            imageData = nil
        }

        // Passthrough fields for cross-platform round-trip
        thinkingDuration = try container.decodeIfPresent(Double.self, forKey: .thinkingDuration)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        multimodalText = try container.decodeIfPresent(String.self, forKey: .multimodalText)
        documents = try container.decodeIfPresent([DocumentName].self, forKey: .documents)
        webSearchBeforeThinking = try container.decodeIfPresent(Bool.self, forKey: .webSearchBeforeThinking)
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations)
        searchReasoning = try container.decodeIfPresent(String.self, forKey: .searchReasoning)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role.rawValue, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(thoughts, forKey: .thoughts)
        try container.encode(isThinking, forKey: .isThinking)
        try container.encode(Self.iso8601Formatter.string(from: timestamp), forKey: .timestamp)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(streamError, forKey: .streamError)
        try container.encodeIfPresent(generationTimeSeconds, forKey: .generationTimeSeconds)
        try container.encode(contentChunks, forKey: .contentChunks)
        // Encode as "webSearch" for React app compatibility
        try container.encodeIfPresent(webSearchState, forKey: .webSearch)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encodeIfPresent(documentContent, forKey: .documentContent)
        try container.encodeIfPresent(imageData, forKey: .imageData)

        // Passthrough fields for cross-platform round-trip
        try container.encodeIfPresent(thinkingDuration, forKey: .thinkingDuration)
        try container.encodeIfPresent(isError, forKey: .isError)
        try container.encodeIfPresent(multimodalText, forKey: .multimodalText)
        try container.encodeIfPresent(documents, forKey: .documents)
        try container.encodeIfPresent(webSearchBeforeThinking, forKey: .webSearchBeforeThinking)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(searchReasoning, forKey: .searchReasoning)
    }
}

// MARK: - Haptic Feedback

/// Utility for handling haptic feedback in chat interactions
enum HapticFeedback {
    /// Available haptic feedback types for chat interactions
    enum FeedbackType {
        case error
        case success
    }

    /// Triggers haptic feedback of specified type if enabled in settings
    static func trigger(_ type: FeedbackType) {
        let hapticEnabled = UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
        guard hapticEnabled else { return }

        let generator = UINotificationFeedbackGenerator()
        switch type {
        case .error:
            generator.notificationOccurred(.error)
        case .success:
            generator.notificationOccurred(.success)
        }
    }
}

// MARK: - API Key Management

/// Manages API key retrieval for premium models
class APIKeyManager {
    static let shared = APIKeyManager()

    private var apiKey: String?
    private var apiKeyFetchedAt: Date?
    private let apiKeyEndpoint = "\(Constants.API.baseURL)/api/keys/chat"

    private init() {}

    /// Retrieves the API key for premium models
    /// - Returns: API key string or empty string if unavailable
    func getApiKey() async -> String {
        if let existingKey = apiKey,
           let fetchedAt = apiKeyFetchedAt,
           Date().timeIntervalSince(fetchedAt) < Constants.API.chatKeyTTLSeconds {
            return existingKey
        }

        return await fetchFreshApiKey()
    }

    /// Forces a fresh API key fetch, ignoring any cached value
    /// - Returns: API key string or empty string if unavailable
    func fetchFreshApiKey() async -> String {
        clearApiKey()

        do {
            // Try to load Clerk if it's not loaded
            let isLoaded = await Clerk.shared.isLoaded

            if !isLoaded {
                try await Clerk.shared.load()
            }

            // Try a few times with a small delay for the session to be available
            for attempt in 1...3 {
                let session = await Clerk.shared.session
                if let session = session,
                   let tokenResource = session.lastActiveToken {

                    // Create URL request with auth header
                    var request = URLRequest(url: URL(string: apiKeyEndpoint)!)
                    request.httpMethod = "GET"
                    request.addValue("Bearer \(tokenResource.jwt)", forHTTPHeaderField: "Authorization")

                    // Fetch API key from server
                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        return ""
                    }

                    // Parse response
                    if let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let key = responseDict["key"] as? String {
                        // Cache key in memory
                        self.apiKey = key
                        self.apiKeyFetchedAt = Date()
                        return key
                    }

                    return ""
                }

                // Wait a bit before trying again (only for first 2 attempts)
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }

            return ""
        } catch {
            return ""
        }
    }

    /// Clears the cached API key
    func clearApiKey() {
        apiKey = nil
        apiKeyFetchedAt = nil
    }
}
