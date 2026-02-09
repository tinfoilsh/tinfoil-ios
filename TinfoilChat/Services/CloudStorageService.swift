//
//  CloudStorageService.swift
//  TinfoilChat
//
//  Service for interacting with cloud storage backend
//

import Foundation
import Clerk

/// Service for managing cloud storage operations
class CloudStorageService: ObservableObject {
    static let shared = CloudStorageService()

    private let apiBaseURL = Constants.API.baseURL
    private var getToken: (() async -> String?)? = nil

    private init() {}

    // MARK: - Configuration

    /// Set the token getter function for authentication
    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) {
        self.getToken = tokenGetter
    }

    /// Default token getter using Clerk
    private func defaultTokenGetter() async -> String? {
        do {
            // Check if Clerk has a publishable key
            guard await !Clerk.shared.publishableKey.isEmpty else {
                return nil
            }

            // Ensure Clerk is loaded
            let isLoaded = await Clerk.shared.isLoaded
            if !isLoaded {
                try await Clerk.shared.load()
            }

            // Get session token
            if let session = await Clerk.shared.session {
                // Get a fresh token
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

    /// Check if user is authenticated
    func isAuthenticated() async -> Bool {
        let token = await (getToken ?? defaultTokenGetter)()
        return token != nil && !token!.isEmpty
    }

    // MARK: - API Headers

    private func getHeaders() async throws -> [String: String] {
        guard let token = await (getToken ?? defaultTokenGetter)() else {
            throw CloudStorageError.authenticationRequired
        }

        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    // MARK: - Conversation ID Generation

    /// Generate a unique conversation ID with reverse timestamp
    func generateConversationId(timestamp: String? = nil) async throws -> GenerateConversationIdResponse {
        let url = URL(string: "\(apiBaseURL)/api/chats/generate-id")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await getHeaders()

        let body = GenerateConversationIdRequest(timestamp: timestamp)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.invalidResponse
        }

        return try JSONDecoder().decode(GenerateConversationIdResponse.self, from: data)
    }

    // MARK: - Upload Operations

    /// Upload a chat to cloud storage
    func uploadChat(_ chat: StoredChat) async throws {
        // Encrypt the chat data first
        let encrypted = try await EncryptionService.shared.encrypt(chat)

        // Create metadata
        let metadata: [String: String] = [
            "db-version": "1",
            "message-count": String(chat.messages.count),
            "chat-created-at": ISO8601DateFormatter().string(from: chat.createdAt),
            "chat-updated-at": ISO8601DateFormatter().string(from: chat.updatedAt)
        ]

        // Create upload request
        let url = URL(string: "\(apiBaseURL)/api/storage/conversation")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = try await getHeaders()

        // Send encrypted data as JSON string
        let encryptedJSON = try JSONEncoder().encode(encrypted)
        let encryptedString = String(data: encryptedJSON, encoding: .utf8)!

        let body = UploadConversationRequest(
            conversationId: chat.id,
            data: encryptedString,
            metadata: metadata,
            projectId: chat.projectId
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.uploadFailed
        }
    }

    // MARK: - Download Operations

    /// Download a chat from cloud storage
    func downloadChat(_ chatId: String) async throws -> StoredChat? {
        let url = URL(string: "\(apiBaseURL)/api/storage/conversation/\(chatId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudStorageError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            throw CloudStorageError.downloadFailed
        }

        let encrypted = try JSONDecoder().decode(EncryptedData.self, from: data)

        // Try to decrypt the chat data
        do {
            let decryptionResult = try await EncryptionService.shared.decrypt(encrypted, as: StoredChat.self)
            let chat = decryptionResult.value

            if decryptionResult.usedFallbackKey {
                scheduleReencryption(for: chat)
            }

            return chat
        } catch {
            // If decryption fails, create a placeholder with encrypted data
            let timestamp = chatId.split(separator: "_").first.map(String.init) ?? ""
            let parsedTimestamp = Int(timestamp) ?? 0
            let createdAtMs = parsedTimestamp > 0 ? Double(9999999999999 - parsedTimestamp) : Date().timeIntervalSince1970 * 1000

            return StoredChat(
                from: await Chat.create(
                    id: chatId,
                    title: "Encrypted",
                    messages: [],
                    createdAt: Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)
                )
            )
        }
    }

    // Re-encrypt with the current key when a legacy key was needed for decryption.
    private func scheduleReencryption(for chat: StoredChat) {
        Task { [weak self] in
            guard let self else { return }
            guard await self.isAuthenticated() else { return }
            guard !chat.messages.isEmpty else { return }

            do {
                var chatForUpload = chat
                chatForUpload.decryptionFailed = false
                chatForUpload.encryptedData = nil
                try await self.uploadChat(chatForUpload)
            } catch {
#if DEBUG
                print("[CloudStorageService] Failed to re-encrypt chat \(chat.id): \(error)")
#endif
            }
        }
    }

    // MARK: - List Operations

    /// List chats from cloud storage with optional pagination
    func listChats(limit: Int? = nil, continuationToken: String? = nil, includeContent: Bool = false) async throws -> ChatListResponse {

        var components = URLComponents(string: "\(apiBaseURL)/api/chats/list")!
        var queryItems: [URLQueryItem] = []

        if let limit = limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let continuationToken = continuationToken {
            queryItems.append(URLQueryItem(name: "continuationToken", value: continuationToken))
        }
        if includeContent {
            queryItems.append(URLQueryItem(name: "includeContent", value: "true"))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }


        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudStorageError.listFailed
        }


        guard httpResponse.statusCode == 200 else {
            throw CloudStorageError.listFailed
        }

        do {
            let result = try JSONDecoder().decode(ChatListResponse.self, from: data)
            return result
        } catch {
            throw error
        }
    }

    // MARK: - Delete Operations

    /// Delete a chat from cloud storage
    func deleteChat(_ chatId: String) async throws {
        let url = URL(string: "\(apiBaseURL)/api/storage/conversation/\(chatId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = try await getHeaders()

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudStorageError.invalidResponse
        }

        // 404 is acceptable for delete (already deleted)
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 404 else {
            throw CloudStorageError.deleteFailed
        }
    }

    // MARK: - Metadata Operations

    /// Update metadata for a chat
    func updateMetadata(chatId: String, metadata: [String: String]) async throws {
        let url = URL(string: "\(apiBaseURL)/api/storage/metadata")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await getHeaders()

        let body = UpdateMetadataRequest(conversationId: chatId, metadata: metadata)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.metadataUpdateFailed
        }
    }

    // MARK: - Sync Status Operations

    /// Get chat sync status (count and lastUpdated) for efficient sync checking
    func getChatSyncStatus() async throws -> ChatSyncStatus {
        let url = URL(string: "\(apiBaseURL)/api/chats/sync-status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.listFailed
        }

        return try JSONDecoder().decode(ChatSyncStatus.self, from: data)
    }

    /// Get IDs of chats deleted since a specific timestamp
    func getDeletedChatsSince(since: String) async throws -> DeletedChatsResponse {
        var components = URLComponents(string: "\(apiBaseURL)/api/chats/deleted-since")!
        components.queryItems = [
            URLQueryItem(name: "since", value: since)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.listFailed
        }

        return try JSONDecoder().decode(DeletedChatsResponse.self, from: data)
    }

    /// Get sync status across ALL chats (regardless of project scope)
    func getAllChatsSyncStatus() async throws -> ChatSyncStatus {
        let url = URL(string: "\(apiBaseURL)/api/chats/all-sync-status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.listFailed
        }

        return try JSONDecoder().decode(ChatSyncStatus.self, from: data)
    }

    /// Get ALL chats updated since a timestamp (not filtered by project)
    func getAllChatsUpdatedSince(since: String) async throws -> ChatListResponse {
        var components = URLComponents(string: "\(apiBaseURL)/api/chats/all-updated-since")!
        components.queryItems = [
            URLQueryItem(name: "since", value: since)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.listFailed
        }

        return try JSONDecoder().decode(ChatListResponse.self, from: data)
    }

    /// Get chats updated since a specific timestamp
    func getChatsUpdatedSince(since: String, includeContent: Bool = false, continuationToken: String? = nil) async throws -> ChatListResponse {
        var components = URLComponents(string: "\(apiBaseURL)/api/chats/updated-since")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "since", value: since)
        ]

        if includeContent {
            queryItems.append(URLQueryItem(name: "includeContent", value: "true"))
        }

        if let continuationToken = continuationToken {
            queryItems.append(URLQueryItem(name: "continuationToken", value: continuationToken))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CloudStorageError.listFailed
        }

        return try JSONDecoder().decode(ChatListResponse.self, from: data)
    }
}

// MARK: - Cloud Storage Errors

enum CloudStorageError: LocalizedError {
    case authenticationRequired
    case invalidResponse
    case uploadFailed
    case downloadFailed
    case listFailed
    case deleteFailed
    case metadataUpdateFailed
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Authentication required for cloud storage"
        case .invalidResponse:
            return "Invalid response from server"
        case .uploadFailed:
            return "Failed to upload chat to cloud"
        case .downloadFailed:
            return "Failed to download chat from cloud"
        case .listFailed:
            return "Failed to list chats from cloud"
        case .deleteFailed:
            return "Failed to delete chat from cloud"
        case .metadataUpdateFailed:
            return "Failed to update chat metadata"
        case .encryptionFailed:
            return "Failed to encrypt chat data"
        case .decryptionFailed:
            return "Failed to decrypt chat data"
        }
    }
}
