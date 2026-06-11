//
//  CloudStorageService.swift
//  TinfoilChat
//
//  Cloud storage adapter built on top of the attested sync enclave.
//  The enclave is the only encryptor; the controlplane only ever
//  sees ciphertext from its perspective. Mirrors
//  `services/cloud/cloud-storage.ts` in the webapp.
//

import ClerkKit
import CryptoKit
import Foundation

/// Service for managing cloud storage operations.
class CloudStorageService: ObservableObject {
    static let shared = CloudStorageService()

    private let chatListLimit = Constants.SyncEnclave.chatListLimit
    private let projectChatListLimit = Constants.SyncEnclave.projectChatListLimit
    private var getToken: (() async -> String?)? = nil

    private init() {}

    // MARK: - Configuration

    /// Set the token getter function for authentication. Wires the same
    /// closure into the shared sync enclave client so attested calls
    /// pick up the user's Clerk JWT automatically. Returns once the
    /// actor-isolated client has accepted the getter so callers can't
    /// race the first authenticated request against an empty token
    /// cache.
    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) async {
        self.getToken = tokenGetter
        let captured = tokenGetter
        await SyncEnclaveClient.shared.setTokenGetter { await captured() }
    }

    /// Default token getter using Clerk.
    private func defaultTokenGetter() async -> String? {
        do {
            guard await !Clerk.shared.publishableKey.isEmpty else {
                return nil
            }

            let isLoaded = await Clerk.shared.isLoaded
            if !isLoaded {
                try await Clerk.shared.refreshClient()
            }

            if let session = await Clerk.shared.session {
                if let token = try? await session.getToken() {
                    return token
                }
                if let tokenResource = session.lastActiveToken {
                    return tokenResource.jwt
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Check if user is authenticated.
    func isAuthenticated() async -> Bool {
        let token = await (getToken ?? defaultTokenGetter)()
        return token != nil && !token!.isEmpty
    }

    // MARK: - Conversation ID generation

    /// Generate a unique conversation ID with reverse timestamp via the
    /// controlplane's helper endpoint. The id format is shared with the
    /// webapp so chats stay sortable cross-device.
    func generateConversationId(timestamp: String? = nil) async throws -> GenerateConversationIdResponse {
        let url = URL(string: "\(Constants.API.baseURL)/api/chats/generate-id")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await getControlplaneHeaders()

        let body = GenerateConversationIdRequest(timestamp: timestamp)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudStorageError.invalidResponse
        }
        return try JSONDecoder().decode(GenerateConversationIdResponse.self, from: data)
    }

    // MARK: - Upload

    struct AttachmentRewrite {
        let clientId: String
        let serverId: String
        let encryptionKey: String
    }

    struct UploadChatResult {
        let syncVersion: Int?
        let rewrites: [AttachmentRewrite]
    }

    /// Push a chat through the sync enclave. The caller's CEK (raw
    /// bytes from `EncryptionService`) is base64-encoded and sent on
    /// the wire; the enclave seals the row under v2 AAD and returns
    /// the new etag, which we surface as the chat's new sync version.
    ///
    /// Returns the new syncVersion alongside any attachment rewrites
    /// (client-minted id → enclave-minted id + per-attachment key) so
    /// the caller can persist them against the freshest local copy
    /// without mutating the chat object passed in.
    @discardableResult
    func uploadChat(_ chat: StoredChat, idempotencyKey: String) async throws -> UploadChatResult {
        var chatToUpload = chat
        let rewrites = try await encryptAndUploadAttachments(
            &chatToUpload,
            idempotencyKey: idempotencyKey
        )
        stripBase64FromMessages(&chatToUpload.messages)

        let plaintext = try JSONEncoder().encode(chatToUpload)
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()

        var metadata: [String: AnyCodable] = [
            "messageCount": AnyCodable(chatToUpload.messages.count)
        ]
        // Always emit projectId so the enclave→controlplane path
        // mirrors what the local chat row says. nil clears the
        // server's project_id column; omitting the field would leave
        // a stale assignment behind on cross-project moves.
        if let projectId = chatToUpload.projectId {
            metadata["projectId"] = AnyCodable(projectId)
        } else {
            metadata["projectId"] = AnyCodable(NSNull())
        }

        let ifMatch: String? = chatToUpload.syncVersion > 0
            ? String(chatToUpload.syncVersion)
            : "0"
        let response = try await SyncEnclaveAPI.push(
            EnclavePushRequest(
                scope: .chat,
                id: chatToUpload.id,
                key: keyB64,
                plaintext: plaintext.base64EncodedString(),
                ifMatch: ifMatch,
                idempotencyKey: idempotencyKey,
                metadata: metadata
            )
        )
        return UploadChatResult(
            syncVersion: etagToSyncVersion(response.etag),
            rewrites: rewrites
        )
    }

    private func encryptAndUploadAttachments(
        _ chat: inout StoredChat,
        idempotencyKey: String
    ) async throws -> [AttachmentRewrite] {
        var rewrites: [AttachmentRewrite] = []
        var attachmentIndex = 0
        for msgIdx in chat.messages.indices {
            for attIdx in chat.messages[msgIdx].attachments.indices {
                defer { attachmentIndex += 1 }
                let att = chat.messages[msgIdx].attachments[attIdx]
                guard att.type == .image,
                      let base64 = att.base64,
                      att.encryptionKey == nil,
                      let raw = Data(base64Encoded: base64) else {
                    continue
                }
                let attIdemKey = attachmentIdempotencyKey(
                    uploadKey: idempotencyKey,
                    attachmentIndex: attachmentIndex
                )
                // The enclave mints both the durable attachment id
                // and a fresh per-attachment AES-256 key. The chat
                // envelope (sealed under the user's CEK) is what
                // keeps the per-attachment keys confidential at rest.
                let result = try await SyncEnclaveAPI.attachmentPut(
                    EnclaveAttachmentPutRequest(
                        chatId: chat.id,
                        plaintext: raw.base64EncodedString(),
                        idempotencyKey: attIdemKey
                    )
                )
                rewrites.append(
                    AttachmentRewrite(
                        clientId: att.id,
                        serverId: result.id,
                        encryptionKey: result.attKey
                    )
                )
                chat.messages[msgIdx].attachments[attIdx].id = result.id
                chat.messages[msgIdx].attachments[attIdx].encryptionKey = result.attKey
            }
        }
        return rewrites
    }

    private func stripBase64FromMessages(_ messages: inout [Message]) {
        for msgIdx in messages.indices {
            for attIdx in messages[msgIdx].attachments.indices {
                if messages[msgIdx].attachments[attIdx].type == .image {
                    messages[msgIdx].attachments[attIdx].base64 = nil
                }
            }
        }
    }

    private func attachmentIdempotencyKey(uploadKey: String, attachmentIndex: Int) -> String {
        let input = "attachment:\(uploadKey):\(attachmentIndex)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download

    /// Pull a chat from the enclave by id. Returns nil for NOT_FOUND.
    /// The enclave returns plaintext (v2); we JSON-decode it into the
    /// local `StoredChat` shape. On unexpected decode failure we keep
    /// the legacy placeholder behavior so the rest of the app can
    /// still display the chat row.
    func downloadChat(_ chatId: String) async throws -> StoredChat? {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return nil }
        let response = try await SyncEnclaveAPI.pull(
            EnclavePullRequest(
                scope: .chat,
                ids: [chatId],
                all: nil,
                cursor: nil,
                limit: nil,
                keys: keys
            )
        )
        guard let item = response.items.first else { return nil }

        if !item.ok {
            if item.code == WireCodes.notFound { return nil }
            return encryptedPlaceholder(chatId: chatId)
        }

        guard let plaintextB64 = item.plaintext,
              let plaintext = Data(base64Encoded: plaintextB64) else {
            return nil
        }

        do {
            var chat = try JSONDecoder().decode(StoredChat.self, from: plaintext)
            chat.formatVersion = 2
            if let syncVersion = etagToSyncVersion(item.etag) {
                chat.syncVersion = syncVersion
            }
            return chat
        } catch {
            return encryptedPlaceholder(chatId: chatId)
        }
    }

    private func encryptedPlaceholder(chatId: String) -> StoredChat {
        let timestamp = chatId.split(separator: "_").first.map(String.init) ?? ""
        let parsedTimestamp = Int(timestamp) ?? 0
        let createdAtMs = parsedTimestamp > 0
            ? Double(Constants.Sync.maxReverseTimestamp - parsedTimestamp)
            : Date().timeIntervalSince1970 * 1000
        return StoredChat.encryptedPlaceholder(
            id: chatId,
            createdAt: Date(timeIntervalSince1970: createdAtMs / 1000.0),
            updatedAt: Date()
        )
    }

    // MARK: - Attachments

    /// Fetch and decrypt all image attachments that have no base64 yet.
    /// Returns a dictionary mapping attachment IDs to their decoded
    /// base64 strings so callers can merge results into the current
    /// (possibly updated) messages without overwriting the entire
    /// array with a stale snapshot.
    func loadImages(in messages: [Message]) async -> [String: String] {
        var work: [(String, String)] = []
        for msg in messages {
            for att in msg.attachments {
                guard att.type == .image,
                      att.base64 == nil,
                      let attKey = att.encryptionKey else { continue }
                work.append((att.id, attKey))
            }
        }
        guard !work.isEmpty else { return [:] }

        var results: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for (attId, key) in work {
                group.addTask {
                    do {
                        let bytes = try await SyncEnclaveAPI.attachmentGet(
                            EnclaveAttachmentGetRequest(id: attId, attKey: key)
                        )
                        return (attId, bytes.base64EncodedString())
                    } catch {
                        return (attId, nil)
                    }
                }
            }
            for await (attId, base64) in group {
                if let b64 = base64 {
                    results[attId] = b64
                }
            }
        }
        return results
    }

    // MARK: - List

    func listChats(
        limit: Int? = nil,
        continuationToken: String? = nil,
        includeContent: Bool = false
    ) async throws -> ChatListResponse {
        let effectiveLimit = min(limit ?? chatListLimit, Constants.SyncEnclave.listStatusPageLimit)
        let status = try await SyncEnclaveAPI.listStatus(
            EnclaveListStatusRequest(
                scope: .chat,
                cursor: continuationToken,
                limit: effectiveLimit,
                projectId: nil,
                direction: "desc"
            )
        )
        var conversations = status.updates.map(remoteChatFromStatus)
        if includeContent && !conversations.isEmpty {
            await attachInlineContent(&conversations)
        }
        return ChatListResponse(
            conversations: conversations,
            nextContinuationToken: status.nextCursor,
            hasMore: hasNextCursor(status.nextCursor)
        )
    }

    func getChatsUpdatedSince(
        since: String,
        includeContent: Bool = false,
        continuationToken: String? = nil
    ) async throws -> ChatListResponse {
        let status = try await SyncEnclaveAPI.listStatus(
            EnclaveListStatusRequest(
                scope: .chat,
                cursor: continuationToken ?? since,
                limit: chatListLimit,
                projectId: nil
            )
        )
        var conversations = status.updates.map(remoteChatFromStatus)
        if includeContent && !conversations.isEmpty {
            await attachInlineContent(&conversations)
        }
        return ChatListResponse(
            conversations: conversations,
            nextContinuationToken: status.nextCursor,
            hasMore: hasNextCursor(status.nextCursor)
        )
    }

    func getAllChatsSyncStatus() async throws -> ChatSyncStatus {
        try await getChatSyncStatus()
    }

    func getAllChatsUpdatedSince(
        since: String,
        continuationToken: String? = nil
    ) async throws -> ChatListResponse {
        try await getChatsUpdatedSince(
            since: since,
            includeContent: true,
            continuationToken: continuationToken
        )
    }

    // MARK: - Sync status

    /// Walk the enclave list-status pages and return the aggregate
    /// count + most-recent updated_at.
    func getChatSyncStatus() async throws -> ChatSyncStatus {
        var count = 0
        var lastUpdated: String? = nil
        var cursor: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(scope: .chat, cursor: cursor, limit: Constants.SyncEnclave.listStatusPageLimit, projectId: nil)
            )
            count += status.updates.count
            for update in status.updates {
                if let prev = lastUpdated {
                    if update.updatedAt > prev { lastUpdated = update.updatedAt }
                } else {
                    lastUpdated = update.updatedAt
                }
            }
            cursor = status.nextCursor
        } while hasNextCursor(cursor)
        return ChatSyncStatus(count: count, lastUpdated: lastUpdated)
    }

    func getDeletedChatsSince(since: String) async throws -> DeletedChatsResponse {
        var deletedIds: [String] = []
        var cursor: String? = since
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(scope: .chat, cursor: cursor, limit: Constants.SyncEnclave.listStatusPageLimit, projectId: nil)
            )
            for entry in status.deletes {
                deletedIds.append(entry.id)
            }
            cursor = status.nextCursor
        } while hasNextCursor(cursor)
        return DeletedChatsResponse(deletedIds: deletedIds)
    }

    // MARK: - Delete

    /// Delete a single chat. Uses an unconditional `if_match=null` so
    /// the enclave handles stale-etag retries internally.
    func deleteChat(_ chatId: String) async throws {
        let key = try CEKEncoding.requirePrimaryKeyB64()
        _ = try await SyncEnclaveAPI.deleteRow(
            EnclaveDeleteRequest(
                scope: .chat,
                id: chatId,
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                key: key
            )
        )
    }

    /// Delete every chat for the current user. Paginates list-status
    /// and issues one delete per row.
    @discardableResult
    func deleteAllChats() async throws -> Int {
        let key = try CEKEncoding.requirePrimaryKeyB64()
        var deleted = 0
        var cursor: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(scope: .chat, cursor: cursor, limit: Constants.SyncEnclave.listStatusPageLimit, projectId: nil)
            )
            for update in status.updates {
                _ = try await SyncEnclaveAPI.deleteRow(
                    EnclaveDeleteRequest(
                        scope: .chat,
                        id: update.id,
                        ifMatch: nil,
                        idempotencyKey: newSyncEnclaveIdempotencyKey(),
                        key: key
                    )
                )
                deleted += 1
            }
            cursor = status.nextCursor
        } while hasNextCursor(cursor)
        return deleted
    }

    // MARK: - Project chat operations

    func listProjectChats(
        projectId: String,
        includeContent: Bool = false,
        continuationToken: String? = nil
    ) async throws -> ProjectChatListResponse {
        var chats: [RemoteChat] = []
        var cursor = continuationToken
        var nextContinuationToken: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: .chat,
                    cursor: cursor,
                    limit: projectChatListLimit,
                    projectId: projectId
                )
            )
            chats.append(contentsOf: status.updates
                .filter { $0.projectId == projectId }
                .map(remoteChatFromStatus))
            cursor = status.nextCursor
            nextContinuationToken = status.nextCursor
            if chats.count >= projectChatListLimit { break }
        } while hasNextCursor(cursor)

        if includeContent && !chats.isEmpty {
            await attachInlineContent(&chats)
        }

        return ProjectChatListResponse(
            chats: chats,
            hasMore: hasNextCursor(nextContinuationToken),
            nextContinuationToken: nextContinuationToken
        )
    }

    func getProjectChatsSyncStatus(projectId: String) async throws -> ChatSyncStatus {
        var count = 0
        var lastUpdated: String? = nil
        var cursor: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: .chat,
                    cursor: cursor,
                    limit: Constants.SyncEnclave.listStatusPageLimit,
                    projectId: projectId
                )
            )
            for update in status.updates {
                guard update.projectId == projectId else { continue }
                count += 1
                if let prev = lastUpdated {
                    if update.updatedAt > prev { lastUpdated = update.updatedAt }
                } else {
                    lastUpdated = update.updatedAt
                }
            }
            cursor = status.nextCursor
        } while hasNextCursor(cursor)
        return ChatSyncStatus(count: count, lastUpdated: lastUpdated)
    }

    func getProjectChatsUpdatedSince(
        projectId: String,
        since: String,
        continuationToken: String? = nil
    ) async throws -> ProjectChatListResponse {
        var chats: [RemoteChat] = []
        var cursor: String? = continuationToken ?? since
        var nextContinuationToken: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: .chat,
                    cursor: cursor,
                    limit: projectChatListLimit,
                    projectId: projectId
                )
            )
            chats.append(contentsOf: status.updates
                .filter { $0.projectId == projectId && $0.updatedAt > since }
                .map(remoteChatFromStatus))
            cursor = status.nextCursor
            nextContinuationToken = status.nextCursor
            if chats.count >= projectChatListLimit { break }
        } while hasNextCursor(cursor)

        // Hydrate inline content for the whole page in one pull;
        // without it every changed chat falls back to an individual
        // download in the delta-sync loop.
        if !chats.isEmpty {
            await attachInlineContent(&chats)
        }

        return ProjectChatListResponse(
            chats: chats,
            hasMore: hasNextCursor(nextContinuationToken),
            nextContinuationToken: nextContinuationToken
        )
    }

    // MARK: - Helpers

    private func attachInlineContent(_ conversations: inout [RemoteChat]) async {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return }
        let ids = conversations.map(\.id)
        do {
            let response = try await SyncEnclaveAPI.pull(
                EnclavePullRequest(
                    scope: .chat,
                    ids: ids,
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            )
            var pulledById: [String: (content: String, syncVersion: Int?)] = [:]
            for item in response.items {
                if !item.ok { continue }
                guard let b64 = item.plaintext,
                      let data = Data(base64Encoded: b64),
                      let content = String(data: data, encoding: .utf8) else { continue }
                pulledById[item.id] = (content, etagToSyncVersion(item.etag))
            }
            for index in conversations.indices {
                let existing = conversations[index]
                guard let pulled = pulledById[existing.id] else { continue }
                conversations[index] = RemoteChat(
                    id: existing.id,
                    key: existing.key,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt,
                    title: existing.title,
                    messageCount: existing.messageCount,
                    syncVersion: pulled.syncVersion ?? existing.syncVersion,
                    size: existing.size,
                    content: pulled.content,
                    formatVersion: 2,
                    projectId: existing.projectId
                )
            }
        } catch {
            // Listing succeeded; surface only metadata when content
            // pulls fail. Callers fall back to per-chat downloads.
        }
    }

    private func remoteChatFromStatus(_ update: EnclaveListStatusUpdate) -> RemoteChat {
        return RemoteChat(
            id: update.id,
            key: nil,
            createdAt: createdAtFromReverseId(update.id),
            updatedAt: update.updatedAt,
            title: nil,
            messageCount: nil,
            syncVersion: etagToSyncVersion(update.etag) ?? 1,
            size: nil,
            content: nil,
            formatVersion: 2,
            projectId: update.projectId
        )
    }

    private func etagToSyncVersion(_ etag: String?) -> Int? {
        guard let etag, let value = Int(etag), value > 0 else { return nil }
        return value
    }

    private func hasNextCursor(_ cursor: String?) -> Bool {
        guard let cursor else { return false }
        return !cursor.isEmpty
    }

    private func createdAtFromReverseId(_ id: String) -> String {
        guard let prefix = id.split(separator: "_").first,
              let reverse = Int(prefix) else {
            return ISO8601DateFormatter.enclaveFractional.string(from: Date())
        }
        let ms = Constants.Sync.maxReverseTimestamp - reverse
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return ISO8601DateFormatter.enclaveFractional.string(from: date)
    }

    // MARK: - Controlplane headers (id generation only)

    private func getControlplaneHeaders(contentType: String = "application/json") async throws -> [String: String] {
        guard let token = await (getToken ?? defaultTokenGetter)(), !token.isEmpty else {
            throw CloudStorageError.authenticationRequired
        }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": contentType
        ]
    }
}

// MARK: - Errors

enum CloudStorageError: LocalizedError {
    case authenticationRequired
    case invalidResponse
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Authentication required for cloud storage"
        case .invalidResponse:
            return "Invalid response from server"
        case .downloadFailed:
            return "Failed to download chat from cloud"
        }
    }
}

private extension ISO8601DateFormatter {
    static let enclaveFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
