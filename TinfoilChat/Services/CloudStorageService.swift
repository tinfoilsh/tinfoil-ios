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
    func setTokenGetter(_ tokenGetter: @escaping SyncEnclaveClient.TokenGetter) async {
        self.getToken = { await tokenGetter(false) }
        await SyncEnclaveClient.shared.setTokenGetter(tokenGetter)
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
    func uploadChat(
        _ chat: StoredChat,
        idempotencyKey: String
    ) async throws -> UploadChatResult {
        var chatToUpload = chat
        let rewrites = try await encryptAndUploadAttachments(&chatToUpload)
        stripBase64FromMessages(&chatToUpload.messages)

        let includesProjectIntent = ProjectMetadataUploadPolicy.shouldInclude(
            syncVersion: chatToUpload.syncVersion,
            projectLocallyModified: chatToUpload.projectLocallyModified == true
        )
        chatToUpload.projectLocallyModified = nil
        let plaintext = try Self.encodeChatPlaintext(chatToUpload)
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()

        var metadata: [String: AnyCodable] = [
            "messageCount": AnyCodable(chatToUpload.messages.count)
        ]
        if includesProjectIntent {
            if let projectId = chatToUpload.projectId {
                metadata["projectId"] = AnyCodable(projectId)
            } else {
                metadata["projectId"] = AnyCodable(NSNull())
            }
        }

        let ifMatch = chatToUpload.syncVersion > 0
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
        _ chat: inout StoredChat
    ) async throws -> [AttachmentRewrite] {
        var rewrites: [AttachmentRewrite] = []
        for msgIdx in chat.messages.indices {
            for attIdx in chat.messages[msgIdx].attachments.indices {
                let att = chat.messages[msgIdx].attachments[attIdx]
                guard att.type == .image,
                      let base64 = att.base64,
                      att.encryptionKey == nil,
                      let raw = Data(base64Encoded: base64) else {
                    continue
                }
                let attIdemKey = Self.attachmentIdempotencyKey(
                    chatId: chat.id,
                    clientId: att.id,
                    plaintext: raw
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

    static func encodeChatPlaintext(_ chat: StoredChat) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(chat)
    }

    static func attachmentIdempotencyKey(
        chatId: String,
        clientId: String,
        plaintext: Data
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("attachment:\(chatId):\(clientId):".utf8))
        hasher.update(data: plaintext)
        let digest = hasher.finalize()
        return dataToHex(Data(digest.prefix(16)))
    }

    // MARK: - Download

    /// Pull a chat from the enclave by id. Returns nil for NOT_FOUND.
    /// The enclave returns plaintext (v2); we JSON-decode it into the
    /// local `StoredChat` shape.
    func downloadChat(_ chatId: String) async throws -> StoredChat? {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else {
            throw CloudStorageError.missingDecryptionKey
        }
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
        guard let item = response.items.first else {
            throw CloudStorageError.invalidResponse
        }

        return try Self.decodeDownloadedChat(item, expectedChatId: chatId)
    }

    static func decodeDownloadedChat(
        _ item: EnclavePullItem,
        expectedChatId: String? = nil
    ) throws -> StoredChat? {
        if let expectedChatId, item.id != expectedChatId {
            throw CloudStorageError.invalidChatPayload
        }
        if !item.ok {
            if item.code == WireCodes.notFound { return nil }
            throw SyncEnclaveError(
                message: "The cloud chat could not be opened",
                code: item.code
            )
        }
        guard let plaintextB64 = item.plaintext,
              let plaintext = Data(base64Encoded: plaintextB64) else {
            throw CloudStorageError.invalidChatPayload
        }
        do {
            var chat = try JSONDecoder().decode(StoredChat.self, from: plaintext)
            guard chat.id == (expectedChatId ?? item.id) else {
                throw CloudStorageError.invalidChatPayload
            }
            chat.formatVersion = 2
            if let etag = item.etag, let syncVersion = Int(etag), syncVersion > 0 {
                chat.syncVersion = syncVersion
            }
            if item.projectIdSet == true {
                chat.projectId = item.projectId
            }
            chat.projectLocallyModified = false
            return chat
        } catch {
            throw CloudStorageError.invalidChatPayload
        }
    }

    func downloadChats(_ ids: [String]) async throws -> [String: StoredChat] {
        guard !ids.isEmpty else { return [:] }
        guard let keys = CEKEncoding.pullKeysIfAvailable() else {
            throw CloudStorageError.missingDecryptionKey
        }
        var chats: [String: StoredChat] = [:]
        for batchStart in stride(from: 0, to: ids.count, by: Constants.SyncEnclave.pullBatchSize) {
            let batch = Array(
                ids[batchStart..<min(batchStart + Constants.SyncEnclave.pullBatchSize, ids.count)]
            )
            let response = try await SyncEnclaveAPI.pull(
                EnclavePullRequest(
                    scope: .chat,
                    ids: batch,
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            )
            var itemsById: [String: EnclavePullItem] = [:]
            for item in response.items where itemsById[item.id] == nil {
                itemsById[item.id] = item
            }
            for id in batch {
                guard let item = itemsById[id],
                      let chat = try Self.decodeDownloadedChat(item, expectedChatId: id) else {
                    throw RevisionSyncError.incompletePull
                }
                chats[id] = chat
            }
        }
        return chats
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
        let effectiveLimit = min(
            limit ?? chatListLimit,
            Constants.SyncEnclave.listStatusPageLimit
        )
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

    func hasAnyChats() async throws -> Bool {
        let snapshot = try await SyncEnclaveAPI.revisionSnapshot(
            EnclaveRevisionSnapshotRequest(cursor: nil, limit: 1)
        )
        return !snapshot.items.isEmpty
    }

    // MARK: - Delete

    /// Delete a single chat. Uses an unconditional `if_match=null` so
    /// the enclave handles stale-etag retries internally.
    func deleteChat(_ chatId: String, idempotencyKey: String) async throws {
        let key = try CEKEncoding.requirePrimaryKeyB64()
        _ = try await SyncEnclaveAPI.deleteRow(
            EnclaveDeleteRequest(
                scope: .chat,
                id: chatId,
                ifMatch: nil,
                idempotencyKey: idempotencyKey,
                key: key
            )
        )
    }

    /// Delete every chat for the current user. Paginates a stable v2 snapshot
    /// and issues one delete per row.
    @discardableResult
    func deleteAllChats() async throws -> Int {
        let key = try CEKEncoding.requirePrimaryKeyB64()
        var chatIds: [String] = []
        var cursor: String? = nil
        var snapshotRevision: String?
        repeat {
            let snapshot = try await SyncEnclaveAPI.revisionSnapshot(
                EnclaveRevisionSnapshotRequest(
                    cursor: cursor,
                    limit: Constants.SyncEnclave.listStatusPageLimit
                )
            )
            guard DecimalRevision.isValid(snapshot.snapshotRevision) else {
                throw RevisionSyncError.invalidRevision
            }
            if let snapshotRevision, snapshotRevision != snapshot.snapshotRevision {
                throw RevisionSyncError.snapshotChangedDuringPagination
            }
            snapshotRevision = snapshot.snapshotRevision
            chatIds.append(contentsOf: snapshot.items.map(\.id))
            cursor = snapshot.nextCursor?.isEmpty == false ? snapshot.nextCursor : nil
        } while hasNextCursor(cursor)

        for chatId in chatIds {
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
        return chatIds.count
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

    // MARK: - Helpers

    /// Pull the full content for the given chats and merge it into the
    /// array in place. Requests are batched so payloads stay bounded no
    /// matter how many chats need content. Chats whose pull fails keep
    /// metadata only; callers fall back to per-chat downloads.
    func attachInlineContent(_ conversations: inout [RemoteChat]) async {
        guard !conversations.isEmpty,
              let keys = CEKEncoding.pullKeysIfAvailable() else { return }
        let ids = conversations.map(\.id)
        var pulledById: [String: (content: String, syncVersion: Int?)] = [:]
        for batchStart in stride(from: 0, to: ids.count, by: Constants.SyncEnclave.pullBatchSize) {
            let batch = Array(ids[batchStart..<min(batchStart + Constants.SyncEnclave.pullBatchSize, ids.count)])
            do {
                let response = try await SyncEnclaveAPI.pull(
                    EnclavePullRequest(
                        scope: .chat,
                        ids: batch,
                        all: nil,
                        cursor: nil,
                        limit: nil,
                        keys: keys
                    )
                )
                for item in response.items {
                    if !item.ok { continue }
                    guard let b64 = item.plaintext,
                          let data = Data(base64Encoded: b64),
                          let content = String(data: data, encoding: .utf8) else { continue }
                    pulledById[item.id] = (content, etagToSyncVersion(item.etag))
                }
            } catch {
                // Listing succeeded; surface only metadata when content
                // pulls fail. Callers fall back to per-chat downloads.
            }
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
    case missingDecryptionKey
    case invalidChatPayload

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Authentication required for cloud storage"
        case .invalidResponse:
            return "Invalid response from server"
        case .downloadFailed:
            return "Failed to download chat from cloud"
        case .missingDecryptionKey:
            return "The cloud encryption key is unavailable"
        case .invalidChatPayload:
            return "The cloud chat data is invalid"
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
