//
//  SyncEnclaveAPI.swift
//  TinfoilChat
//
//  Typed JSON-RPC bindings for the sync enclave's `/v1/*` endpoints.
//  Mirrors `services/sync-enclave/sync-api.ts` in the webapp and the
//  Go source in `confidential-sync/internal/server/types.go`.
//
//  All endpoints are POST with a JSON body and JSON response. The
//  caller is responsible for:
//    - supplying the user's CEK on every push/pull/delete (base64 raw
//      32-byte key);
//    - choosing an idempotency key per logical operation;
//    - passing the ETag the client believes the row is at (or null
//      for a create) via `ifMatch`.
//
//  The enclave owns:
//    - encryption-at-rest (seal/unseal under the user's CEK);
//    - the per-row ETag and `key_id` columns; and
//    - 412 STALE_BLOB / 409 STALE_KEY / SYNC_CONFLICT semantics.
//      The enclave never merges concurrent edits; every conflict is
//      bubbled up to the UI to resolve.
//

import Foundation

enum SyncScope: String, Codable, Sendable {
    case profile
    case chat
    case project
    case projectDocument = "project_document"
}

// MARK: - Sync (push / pull / list-status / delete)

struct EnclavePushRequest: Encodable {
    let scope: SyncScope
    /// Required for every scope. For `profile` the canonical singleton
    /// id is `"profile"` — the enclave no longer substitutes it
    /// silently, so an empty value is a 400.
    let id: String
    let key: String
    let plaintext: String
    let ifMatch: String?
    let idempotencyKey: String
    let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case scope, id, key, plaintext, metadata
        case ifMatch = "if_match"
        case idempotencyKey = "idempotency_key"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encode(plaintext, forKey: .plaintext)
        // `if_match` participates in CAS — null is a sentinel for
        // "create new", so we must emit it explicitly rather than
        // omit the key.
        if let ifMatch {
            try container.encode(ifMatch, forKey: .ifMatch)
        } else {
            try container.encodeNil(forKey: .ifMatch)
        }
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

struct EnclavePushResponse: Decodable {
    let ok: Bool
    let etag: String
    let keyId: String

    enum CodingKeys: String, CodingKey {
        case ok, etag
        case keyId = "key_id"
    }
}

struct EnclavePullKey: Codable {
    /// base64 32-byte raw key.
    let key: String
    /// Optional hint; enclave verifies/derives.
    let keyId: String?

    enum CodingKeys: String, CodingKey {
        case key
        case keyId = "key_id"
    }

    init(key: String, keyId: String? = nil) {
        self.key = key
        self.keyId = keyId
    }
}

struct EnclavePullRequest: Encodable {
    let scope: SyncScope
    let ids: [String]?
    let all: Bool?
    let cursor: String?
    let limit: Int?
    /// Candidate decryption keys, in priority order. Enclave tries
    /// each one when unsealing v0/v1 rows and uses `keys[0]` as the
    /// rewrap target so legacy rows are promoted to v2 inline before
    /// the response is returned — callers don't have to opt in.
    let keys: [EnclavePullKey]

    enum CodingKeys: String, CodingKey {
        case scope, ids, all, cursor, limit, keys
    }
}

struct EnclavePullItem: Decodable {
    let id: String
    let ok: Bool
    /// Base64-encoded plaintext bytes when `ok=true`.
    let plaintext: String?
    let keyId: String?
    let etag: String?
    let needsRewrap: Bool?
    /// Error code when `ok=false` (e.g. "NEEDS_REWRAP", "NOT_FOUND").
    let code: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, ok, plaintext, etag, reason, code
        case keyId = "key_id"
        case needsRewrap = "needs_rewrap"
    }
}

struct EnclavePullResponse: Decodable {
    let items: [EnclavePullItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }

    // Go marshals an empty slice as JSON null, which JSONDecoder
    // would otherwise reject as a corrupt array. Normalize to [] so
    // callers can iterate without guards.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([EnclavePullItem].self, forKey: .items) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct EnclaveListStatusRequest: Encodable {
    let scope: SyncScope
    let cursor: String?
    let limit: Int?
    /// Optional server-side project filter for chat scope.
    let projectId: String?

    enum CodingKeys: String, CodingKey {
        case scope, cursor, limit
        case projectId = "project_id"
    }
}

struct EnclaveListStatusUpdate: Decodable {
    let id: String
    let etag: String
    let keyId: String
    /// Server-supplied project membership for chat rows; absent for other scopes.
    let projectId: String?
    let updatedAt: String
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case id, etag, cursor
        case keyId = "key_id"
        case projectId = "project_id"
        case updatedAt = "updated_at"
    }
}

struct EnclaveListStatusDelete: Decodable {
    let id: String
    let scope: SyncScope
    let deletedAt: String
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case id, scope, cursor
        case deletedAt = "deleted_at"
    }
}

struct EnclaveListStatusResponse: Decodable {
    let updates: [EnclaveListStatusUpdate]
    let deletes: [EnclaveListStatusDelete]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case updates, deletes
        case nextCursor = "next_cursor"
    }

    // Both arrays land as JSON null when the server has nothing to
    // report for the page; normalize so iteration in CloudStorage /
    // ProfileSync stays branchless.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updates = try c.decodeIfPresent([EnclaveListStatusUpdate].self, forKey: .updates) ?? []
        deletes = try c.decodeIfPresent([EnclaveListStatusDelete].self, forKey: .deletes) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct EnclaveDeleteRequest: Encodable {
    let scope: SyncScope
    let id: String
    let ifMatch: String?
    let idempotencyKey: String
    /// Base64 CEK; required to derive the op-hash key per spec §7.0.
    let key: String

    enum CodingKeys: String, CodingKey {
        case scope, id, key
        case ifMatch = "if_match"
        case idempotencyKey = "idempotency_key"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(id, forKey: .id)
        if let ifMatch {
            try container.encode(ifMatch, forKey: .ifMatch)
        } else {
            try container.encodeNil(forKey: .ifMatch)
        }
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(key, forKey: .key)
    }
}

struct EnclaveOKResponse: Decodable {
    let ok: Bool
}

// MARK: - Key registry

struct EnclaveKeyRegisterBundleInput: Encodable {
    let credentialId: String
    let kekIvHex: String
    let encryptedKeysHex: String

    enum CodingKeys: String, CodingKey {
        case credentialId = "credential_id"
        case kekIvHex = "kek_iv"
        case encryptedKeysHex = "encrypted_keys"
    }
}

struct EnclaveKeyRegisterRequest: Encodable {
    let key: String
    /// "" / sentinels per IfMatchSentinels. Required by the enclave.
    let ifMatch: String
    let createdVia: String
    let idempotencyKey: String
    let initialBundle: EnclaveKeyRegisterBundleInput?

    enum CodingKeys: String, CodingKey {
        case key
        case ifMatch = "if_match"
        case createdVia = "created_via"
        case idempotencyKey = "idempotency_key"
        case initialBundle = "initial_bundle"
    }
}

struct EnclaveKeyRegisterResponse: Decodable {
    let ok: Bool
    let keyId: String

    enum CodingKeys: String, CodingKey {
        case ok
        case keyId = "key_id"
    }
}

struct EnclaveAddBundleRequest: Encodable {
    let keyId: String
    let key: String
    let credentialId: String
    let kekIvHex: String
    let encryptedKeysHex: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case key
        case credentialId = "credential_id"
        case kekIvHex = "kek_iv"
        case encryptedKeysHex = "encrypted_keys"
        case idempotencyKey = "idempotency_key"
    }
}

struct EnclaveRemoveBundleRequest: Encodable {
    let keyId: String
    let key: String
    let credentialId: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case key
        case credentialId = "credential_id"
        case idempotencyKey = "idempotency_key"
    }
}

struct EnclaveKeyCurrentBundle: Decodable {
    let credentialId: String
    let kekIv: String
    let encryptedKeys: String
    let bundleVersion: Int?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case credentialId = "credential_id"
        case kekIv = "kek_iv"
        case encryptedKeys = "encrypted_keys"
        case bundleVersion = "bundle_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct EnclaveKeyCurrentResponse: Decodable {
    let keyId: String?
    let etag: String?
    let bundles: [String: EnclaveKeyCurrentBundle]
    let createdVia: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case etag, bundles
        case createdVia = "created_via"
        case createdAt = "created_at"
    }
}

// A first-time user has no registered bundles, which Go encodes
// as a null map; default to an empty map so callers can index
// and enumerate without guards. Lives in an extension to keep the
// auto-synthesized memberwise initializer for the 404 fallback.
extension EnclaveKeyCurrentResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyId: try c.decodeIfPresent(String.self, forKey: .keyId),
            etag: try c.decodeIfPresent(String.self, forKey: .etag),
            bundles: try c.decodeIfPresent([String: EnclaveKeyCurrentBundle].self, forKey: .bundles) ?? [:],
            createdVia: try c.decodeIfPresent(String.self, forKey: .createdVia),
            createdAt: try c.decodeIfPresent(String.self, forKey: .createdAt)
        )
    }
}

// MARK: - Migration

struct EnclaveMigrateRequestTarget: Encodable {
    let key: String
}

struct EnclaveMigrateRequest: Encodable {
    let scope: SyncScope
    let ids: [String]?
    let limit: Int?
    let keys: [EnclavePullKey]
    let target: EnclaveMigrateRequestTarget
}

struct EnclaveMigrateResponse: Decodable {
    let migrated: Int
    let retryableRemaining: Int
    let blockedUnmigrated: Int
    let blocked: [String]?

    enum CodingKeys: String, CodingKey {
        case migrated, blocked
        case retryableRemaining = "retryable_remaining"
        case blockedUnmigrated = "blocked_unmigrated"
    }
}

struct EnclaveMigrateAllRequest: Encodable {
    let keys: [EnclavePullKey]
    let target: EnclaveMigrateRequestTarget
}

struct EnclaveMigrateAllScopeReport: Decodable {
    let scope: SyncScope
    let migrated: Int
    let retryableRemaining: Int
    let blockedUnmigrated: Int
    let blocked: [String]?

    enum CodingKeys: String, CodingKey {
        case scope, migrated, blocked
        case retryableRemaining = "retryable_remaining"
        case blockedUnmigrated = "blocked_unmigrated"
    }
}

struct EnclaveMigrateAllResponse: Decodable {
    let migrated: Int
    let retryableRemaining: Int
    let blockedUnmigrated: Int
    /// True when the enclave hit its wall-clock budget before every
    /// scope was drained. The client should re-invoke migrate-all to
    /// pick up where it left off.
    let partial: Bool
    let scopes: [EnclaveMigrateAllScopeReport]

    enum CodingKeys: String, CodingKey {
        case migrated, partial, scopes
        case retryableRemaining = "retryable_remaining"
        case blockedUnmigrated = "blocked_unmigrated"
    }

    // The enclave may return null for scopes when it had nothing to
    // migrate this pass; normalize to [] so the migration loop can
    // aggregate without crashing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        migrated = try c.decode(Int.self, forKey: .migrated)
        retryableRemaining = try c.decode(Int.self, forKey: .retryableRemaining)
        blockedUnmigrated = try c.decode(Int.self, forKey: .blockedUnmigrated)
        partial = try c.decode(Bool.self, forKey: .partial)
        scopes = try c.decodeIfPresent([EnclaveMigrateAllScopeReport].self, forKey: .scopes) ?? []
    }
}

// MARK: - Attachments

struct EnclaveAttachmentPutRequest: Encodable {
    let chatId: String
    let plaintext: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case plaintext
        case idempotencyKey = "idempotency_key"
    }
}

struct EnclaveAttachmentPutResponse: Decodable {
    let ok: Bool
    let id: String
    let attKey: String

    enum CodingKeys: String, CodingKey {
        case ok, id
        case attKey = "att_key"
    }
}

struct EnclaveAttachmentGetRequest: Encodable {
    let id: String
    let attKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case attKey = "att_key"
    }
}

struct EnclaveAttachmentGetResponse: Decodable {
    let ok: Bool
    let plaintext: String
}

struct EnclaveAttachmentDeleteRequest: Encodable {
    let id: String
}

// MARK: - Share (seal/open)

struct EnclaveShareSealRequest: Encodable {
    let plaintext: String
}

struct EnclaveShareSealResponse: Decodable {
    let ok: Bool
    let shareKey: String
    let ciphertext: String

    enum CodingKeys: String, CodingKey {
        case ok, ciphertext
        case shareKey = "share_key"
    }
}

struct EnclaveShareOpenRequest: Encodable {
    let shareKey: String
    let ciphertext: String

    enum CodingKeys: String, CodingKey {
        case ciphertext
        case shareKey = "share_key"
    }
}

struct EnclaveShareOpenResponse: Decodable {
    let ok: Bool
    let plaintext: String
}

// MARK: - Health

struct EnclaveHealthResponse: Decodable {
    let status: String
    let gitSha: String?

    enum CodingKeys: String, CodingKey {
        case status
        case gitSha = "git_sha"
    }
}

// MARK: - API surface

enum SyncEnclaveAPI {

    // MARK: Sync

    static func push(_ request: EnclavePushRequest) async throws -> EnclavePushResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/sync/push", body: request)
    }

    static func pull(_ request: EnclavePullRequest) async throws -> EnclavePullResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/sync/pull", body: request)
    }

    static func pullOne(scope: SyncScope, id: String, keys: [EnclavePullKey]) async throws -> EnclavePullItem? {
        let response: EnclavePullResponse = try await pull(
            EnclavePullRequest(scope: scope, ids: [id], all: nil, cursor: nil, limit: nil, keys: keys)
        )
        return response.items.first
    }

    static func listStatus(_ request: EnclaveListStatusRequest) async throws -> EnclaveListStatusResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/sync/list-status", body: request)
    }

    @discardableResult
    static func deleteRow(_ request: EnclaveDeleteRequest) async throws -> EnclaveOKResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/sync/delete", body: request)
    }

    // MARK: Key registry

    static func registerKey(_ request: EnclaveKeyRegisterRequest) async throws -> EnclaveKeyRegisterResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/key/register", body: request)
    }

    @discardableResult
    static func addBundle(_ request: EnclaveAddBundleRequest) async throws -> EnclaveOKResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/key/add-bundle", body: request)
    }

    @discardableResult
    static func removeBundle(_ request: EnclaveRemoveBundleRequest) async throws -> EnclaveOKResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/key/remove-bundle", body: request)
    }

    /// Fetch the current key id and the full set of passkey bundles
    /// registered for the authenticated user. A 404 maps to a synthetic
    /// `{ key_id: nil, bundles: [:] }` so callers treat first-time users
    /// as an ordinary empty state.
    static func keyCurrent() async throws -> EnclaveKeyCurrentResponse {
        do {
            let response: EnclaveKeyCurrentResponse = try await SyncEnclaveClient.shared.post(
                path: "/v1/key/current",
                body: EmptyBody()
            )
            return response
        } catch let error as SyncEnclaveError where error.status == 404 {
            return EnclaveKeyCurrentResponse(
                keyId: nil,
                etag: nil,
                bundles: [:],
                createdVia: nil,
                createdAt: nil
            )
        }
    }

    // MARK: Migration

    static func migrate(_ request: EnclaveMigrateRequest) async throws -> EnclaveMigrateResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/blobs/migrate", body: request)
    }

    static func migrateAll(_ request: EnclaveMigrateAllRequest) async throws -> EnclaveMigrateAllResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/blobs/migrate-all", body: request)
    }

    // MARK: Attachments

    static func attachmentPut(_ request: EnclaveAttachmentPutRequest) async throws -> EnclaveAttachmentPutResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/attachment/put", body: request)
    }

    static func attachmentGet(_ request: EnclaveAttachmentGetRequest) async throws -> Data {
        let response: EnclaveAttachmentGetResponse = try await SyncEnclaveClient.shared.post(
            path: "/v1/attachment/get",
            body: request
        )
        return try base64ToData(response.plaintext, label: "attachment plaintext")
    }

    static func attachmentGetPublic(_ request: EnclaveAttachmentGetRequest) async throws -> Data {
        let response: EnclaveAttachmentGetResponse = try await SyncEnclaveClient.shared.post(
            path: "/v1/attachment/get-public",
            body: request,
            skipAuth: true
        )
        return try base64ToData(response.plaintext, label: "attachment plaintext")
    }

    @discardableResult
    static func attachmentDelete(id: String) async throws -> EnclaveOKResponse {
        try await SyncEnclaveClient.shared.post(
            path: "/v1/attachment/delete",
            body: EnclaveAttachmentDeleteRequest(id: id)
        )
    }

    // MARK: Share

    static func shareSeal(_ request: EnclaveShareSealRequest) async throws -> EnclaveShareSealResponse {
        try await SyncEnclaveClient.shared.post(path: "/v1/share/seal", body: request)
    }

    static func shareOpen(_ request: EnclaveShareOpenRequest) async throws -> Data {
        let response: EnclaveShareOpenResponse = try await SyncEnclaveClient.shared.post(
            path: "/v1/share/open",
            body: request,
            skipAuth: true
        )
        return try base64ToData(response.plaintext, label: "share plaintext")
    }

    // MARK: Health

    static func health() async throws -> EnclaveHealthResponse {
        try await SyncEnclaveClient.shared.get(path: "/v1/health")
    }
}

// MARK: - Helpers

private struct EmptyBody: Encodable {}

/// Mint a fresh idempotency key for one logical enclave write. The
/// key MUST be reused across every HTTP retry of the same logical
/// write and refreshed when the caller has a new logical write to
/// perform. Format: 32 lowercase hex characters (128 bits from
/// `SecRandomCopyBytes`).
///
/// Traps on CSPRNG failure: a predictable key would silently dedupe
/// against earlier writes via the enclave's idempotency cache, which
/// is worse than crashing the request.
func newSyncEnclaveIdempotencyKey() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Convert raw bytes to base64 (standard, padded).
func dataToBase64(_ data: Data) -> String {
    data.base64EncodedString()
}

/// Convert a base64 string to raw bytes, throwing `SyncEnclaveError`
/// with a descriptive label when the input is malformed.
func base64ToData(_ s: String, label: String) throws -> Data {
    guard let data = Data(base64Encoded: s) else {
        throw SyncEnclaveError(message: "Invalid base64 \(label)")
    }
    return data
}

/// Convert raw bytes to lowercase hex.
func dataToHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Convert a lowercase hex string to raw bytes. Throws when the input
/// is the empty string, an odd-length string, or contains a
/// non-hex character.
func hexToData(_ hex: String) throws -> Data {
    guard !hex.isEmpty else { throw SyncEnclaveError(message: "Empty hex string") }
    guard hex.count % 2 == 0 else { throw SyncEnclaveError(message: "Odd-length hex string") }
    var data = Data(capacity: hex.count / 2)
    var iterator = hex.makeIterator()
    while let high = iterator.next() {
        guard let low = iterator.next() else {
            throw SyncEnclaveError(message: "Odd-length hex string")
        }
        guard let highVal = high.hexDigitValue, let lowVal = low.hexDigitValue else {
            throw SyncEnclaveError(message: "Invalid hex character")
        }
        data.append(UInt8(highVal * 16 + lowVal))
    }
    return data
}

/// Convert a lowercase hex CEK string to base64, the format the
/// enclave's `keyB64` field expects.
func hexCekToBase64(_ hex: String) throws -> String {
    let data = try hexToData(hex)
    return data.base64EncodedString()
}
