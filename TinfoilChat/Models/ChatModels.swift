//
//  ChatModels.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import Foundation
import UIKit
import ClerkKit

/// Represents a chat conversation
struct Chat: Identifiable, Codable {
    enum TitleState: String, Codable {
        case placeholder
        case generated
        case manual
    }

    static let placeholderTitle = "Untitled"

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
    
    // Format version: 0=legacy JSON, 1=gzip+binary
    var formatVersion: Int?

    // Local-only flag: when true, chat is never synced to cloud
    var isLocalOnly: Bool = false

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
        let unpadded = String(reverseTimestamp)
        let reverseTsStr = String(repeating: "0", count: max(0, Constants.Sync.reverseTimestampDigits - unpadded.count)) + unpadded
        return "\(reverseTsStr)_\(UUID().uuidString.lowercased())"
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
        formatVersion: Int? = nil,
        isLocalOnly: Bool = false,
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
        self.formatVersion = formatVersion
        self.isLocalOnly = isLocalOnly
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
        updatedAt: Date? = nil,
        isLocalOnly: Bool = false
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
            updatedAt: updatedAt,
            isLocalOnly: isLocalOnly
        )
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, title, titleState, messages, createdAt, modelType, language, userId
        case syncVersion, syncedAt, locallyModified, updatedAt
        case decryptionFailed, dataCorrupted, encryptedData, formatVersion, isLocalOnly, projectId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        titleState = (try? container.decode(TitleState.self, forKey: .titleState)) ?? Chat.deriveTitleState(for: title, messages: messages)
        // hasActiveStream is transient UI state — always reset to false on decode
        hasActiveStream = false
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
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
        isLocalOnly = try container.decodeIfPresent(Bool.self, forKey: .isLocalOnly) ?? false
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(titleState, forKey: .titleState)
        try container.encode(messages, forKey: .messages)
        // hasActiveStream is transient UI state — never encode it
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
        try container.encodeIfPresent(formatVersion, forKey: .formatVersion)
        try container.encode(isLocalOnly, forKey: .isLocalOnly)
        try container.encodeIfPresent(projectId, forKey: .projectId)
    }
    
    // MARK: - Haptic Feedback Methods

    /// Triggers haptic feedback when a chat operation succeeds
    static func triggerSuccessFeedback() {
        HapticFeedback.trigger(.success)
    }

    // MARK: - Per-Chat File Storage Methods

    /// Routes to `.local` or `.cloud` storage based on `chat.isLocalOnly`.
    static func saveChat(_ chat: Chat, userId: String?) async {
        guard let userId = userId else { return }
        let storage: EncryptedFileStorage = chat.isLocalOnly ? .local : .cloud
        do {
            try await storage.saveChat(chat, userId: userId)
        } catch {
            #if DEBUG
            print("Failed to save chat to file storage: \(error)")
            #endif
        }
    }

    /// Loads the cloud index only (backward compatible for pagination/sync callers).
    static func loadChatIndex(userId: String?) async -> [ChatIndexEntry] {
        guard let userId = userId else { return [] }
        return (try? await EncryptedFileStorage.cloud.loadIndex(userId: userId)) ?? []
    }

    /// Loads the local-only index.
    static func loadLocalChatIndex(userId: String?) async -> [ChatIndexEntry] {
        guard let userId = userId else { return [] }
        return (try? await EncryptedFileStorage.local.loadIndex(userId: userId)) ?? []
    }

    /// Tries local storage first, then cloud.
    static func loadChat(chatId: String, userId: String?) async -> Chat? {
        guard let userId = userId else { return nil }
        if let chat = try? await EncryptedFileStorage.local.loadChat(chatId: chatId, userId: userId) {
            return chat
        }
        return try? await EncryptedFileStorage.cloud.loadChat(chatId: chatId, userId: userId)
    }

    static func loadChats(chatIds: [String], userId: String?) async -> [Chat] {
        guard let userId = userId else { return [] }
        var results: [Chat] = []
        for chatId in chatIds {
            if let chat = await loadChat(chatId: chatId, userId: userId) {
                results.append(chat)
            }
        }
        return results
    }

    /// Loads chats from both stores and merges.
    static func loadAllChats(userId: String?) async -> [Chat] {
        guard let userId = userId else { return [] }
        let localChats = (try? await EncryptedFileStorage.local.loadAllChats(userId: userId)) ?? []
        let cloudChats = (try? await EncryptedFileStorage.cloud.loadAllChats(userId: userId)) ?? []
        return localChats + cloudChats
    }

    /// Tries both stores to ensure the chat is removed wherever it lives.
    static func deleteChatFromStorage(chatId: String, userId: String?) async {
        guard let userId = userId else { return }
        try? await EncryptedFileStorage.local.deleteChat(chatId: chatId, userId: userId)
        try? await EncryptedFileStorage.cloud.deleteChat(chatId: chatId, userId: userId)
    }

    /// Deletes from both stores.
    static func deleteAllChatsFromStorage(userId: String?) async {
        guard let userId = userId else { return }
        try? await EncryptedFileStorage.local.deleteAllChats(userId: userId)
        try? await EncryptedFileStorage.cloud.deleteAllChats(userId: userId)
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

    init(id: String = UUID().uuidString.lowercased(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Generate UUID if id is missing (React app doesn't include it)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
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
    var thinkingChunks: [ThinkingChunk] = []
    var webSearchState: WebSearchState? = nil
    var attachments: [Attachment] = []

    // Passthrough fields for cross-platform round-trip (used by React, preserved by iOS)
    var thinkingDuration: Double? = nil
    var isError: Bool? = nil
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
    
    init(id: String = UUID().uuidString.lowercased(), role: MessageRole, content: String, thoughts: String? = nil, isThinking: Bool = false, timestamp: Date = Date(), isCollapsed: Bool = true, generationTimeSeconds: Double? = nil, contentChunks: [ContentChunk] = [], thinkingChunks: [ThinkingChunk] = [], webSearchState: WebSearchState? = nil, attachments: [Attachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.thoughts = thoughts
        self.isThinking = isThinking
        self.timestamp = timestamp
        self.isCollapsed = isCollapsed
        self.generationTimeSeconds = generationTimeSeconds
        self.contentChunks = contentChunks
        self.thinkingChunks = thinkingChunks
        self.webSearchState = webSearchState
        self.attachments = attachments
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, role, content, thoughts, isThinking, timestamp, isCollapsed, isStreaming, streamError, generationTimeSeconds, webSearchState
        case webSearch // Alternative key used by React app
        case attachments
        case thinkingDuration, isError
        case webSearchBeforeThinking, annotations, searchReasoning
        // Legacy keys for decoding React messages that use the old format
        case documentContent, imageData, imageBase64, multimodalText, documents
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Make id optional for cross-platform compatibility with React
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
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
        // contentChunks and thinkingChunks are transient UI rendering state — never decoded from storage
        contentChunks = []
        thinkingChunks = []
        // Try iOS key first, then React key for cross-platform compatibility
        webSearchState = try container.decodeIfPresent(WebSearchState.self, forKey: .webSearchState)
            ?? container.decodeIfPresent(WebSearchState.self, forKey: .webSearch)
        let decodedAttachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []

        if !decodedAttachments.isEmpty {
            attachments = decodedAttachments
        } else {
            // Reconstruct attachments from legacy React format (documents + imageData + documentContent + multimodalText)
            attachments = Self.reconstructAttachments(from: container)
        }

        // Passthrough fields for cross-platform round-trip
        thinkingDuration = try container.decodeIfPresent(Double.self, forKey: .thinkingDuration)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
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
        // contentChunks is transient UI rendering state — never encode it
        // Encode as "webSearch" for React app compatibility
        try container.encodeIfPresent(webSearchState, forKey: .webSearch)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        // imageData, documents, documentContent, multimodalText are no longer encoded —
        // all attachment data lives in the attachments array

        // Passthrough fields for cross-platform round-trip
        try container.encodeIfPresent(thinkingDuration, forKey: .thinkingDuration)
        try container.encodeIfPresent(isError, forKey: .isError)
        try container.encodeIfPresent(webSearchBeforeThinking, forKey: .webSearchBeforeThinking)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(searchReasoning, forKey: .searchReasoning)
    }

    // MARK: - Legacy Format Reconstruction

    /// Reconstructs attachments from React's legacy format (documents + imageData + documentContent + multimodalText).
    /// React stored these as parallel arrays: documents[i].name paired with imageData[i] for images.
    private static func reconstructAttachments(from container: KeyedDecodingContainer<CodingKeys>) -> [Attachment] {
        // Decode legacy fields
        struct LegacyImageData: Codable {
            let base64: String
            let mimeType: String
        }
        struct LegacyDocumentName: Codable {
            let name: String
        }

        let legacyDocuments = (try? container.decodeIfPresent([LegacyDocumentName].self, forKey: .documents)) ?? nil
        let legacyImageData = (try? container.decodeIfPresent([LegacyImageData].self, forKey: .imageData)) ?? nil
        let legacyImageBase64 = (try? container.decodeIfPresent(String.self, forKey: .imageBase64)) ?? nil
        let legacyDocumentContent = (try? container.decodeIfPresent(String.self, forKey: .documentContent)) ?? nil
        let legacyMultimodalText = (try? container.decodeIfPresent(String.self, forKey: .multimodalText)) ?? nil

        guard legacyDocuments != nil || legacyImageData != nil || legacyImageBase64 != nil else {
            return []
        }

        var result: [Attachment] = []

        if let docs = legacyDocuments {
            // React format: documents[] and imageData[] are parallel arrays.
            // If imageData[i] exists, documents[i] is an image; otherwise it's a document.
            for (i, doc) in docs.enumerated() {
                if let imgArray = legacyImageData, i < imgArray.count {
                    let img = imgArray[i]
                    let description = extractImageDescription(named: doc.name, from: legacyMultimodalText)
                    result.append(Attachment(
                        type: .image,
                        fileName: doc.name,
                        mimeType: img.mimeType,
                        base64: img.base64,
                        description: description ?? doc.name
                    ))
                } else {
                    let textContent = extractDocumentContent(named: doc.name, from: legacyDocumentContent)
                    result.append(Attachment(
                        type: .document,
                        fileName: doc.name,
                        textContent: textContent
                    ))
                }
            }
        } else if let legacyBase64 = legacyImageBase64 {
            // Very old iOS format: single imageBase64 string, no documents array
            result.append(Attachment(
                type: .image,
                fileName: "Image",
                mimeType: Constants.Attachments.defaultImageMimeType,
                base64: legacyBase64,
                description: "Image"
            ))
        }

        return result
    }

    /// Extracts a single image description from the combined multimodalText string.
    /// React format: "Image: {name}\nDescription:\n{description}\n\nImage: {name2}\n..."
    private static func extractImageDescription(named name: String, from multimodalText: String?) -> String? {
        guard let text = multimodalText else { return nil }
        let marker = "Image: \(name)\nDescription:\n"
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        if let nextImage = rest.range(of: "\n\nImage: ") {
            return String(rest[..<nextImage.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts a single document's text content from the combined documentContent string.
    /// React format: "Document title: {name}\nDocument contents:\n{content}\n\nDocument title: {name2}\n..."
    private static func extractDocumentContent(named name: String, from documentContent: String?) -> String? {
        guard let content = documentContent else { return nil }
        let marker = "Document title: \(name)\nDocument contents:\n"
        guard let range = content.range(of: marker) else { return nil }
        let rest = content[range.upperBound...]
        if let nextDoc = rest.range(of: "\nDocument title: ") {
            return String(rest[..<nextDoc.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
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
                try await Clerk.shared.refreshClient()
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
