import Foundation

/// The account's content key as the harness keeps it beside the stored
/// rows: the current key's id, the passkey bundles that wrap it, and
/// whether rows sealed under another key remain.
struct KeyState: Equatable, Sendable {
    struct Bundle: Equatable, Sendable {
        let credentialId: String
        let kekIv: String
        let encryptedKeys: String
        let bundleVersion: Int?
        let createdAt: String?
        let updatedAt: String?
    }

    let keyId: String?
    let etag: String?
    let bundles: [String: Bundle]
    let createdVia: String?
    let createdAt: String?
    /// Rows sealed under a key other than the current one exist. Without a
    /// key id, data predates the registry, and a fresh key would strand it.
    let hasData: Bool

    init(keyId: String?, etag: String?, bundles: [String: Bundle], createdVia: String?, createdAt: String?, hasData: Bool) {
        self.keyId = keyId
        self.etag = etag
        self.bundles = bundles
        self.createdVia = createdVia
        self.createdAt = createdAt
        self.hasData = hasData
    }

    init(_ wire: Components.Schemas.KeyCurrent) {
        keyId = wire.keyId
        etag = wire.etag
        bundles = (wire.bundles?.additionalProperties ?? [:]).mapValues {
            Bundle(
                credentialId: $0.credentialId, kekIv: $0.kekIv, encryptedKeys: $0.encryptedKeys,
                bundleVersion: $0.bundleVersion, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }
        createdVia = wire.createdVia?.rawValue
        createdAt = wire.createdAt
        hasData = wire.hasData ?? false
    }
}

private struct KeyRegisterRequest: Encodable {
    let key: String
    let ifMatch: String
    let createdVia: String
    let idempotencyKey: String
    let initialBundle: KeyBundleInput?

    enum CodingKeys: String, CodingKey {
        case key
        case ifMatch = "if_match"
        case createdVia = "created_via"
        case idempotencyKey = "idempotency_key"
        case initialBundle = "initial_bundle"
    }
}

private struct KeyRegistered: Decodable {
    let keyId: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
    }
}

private struct AddBundleRequest: Encodable {
    let keyId: String
    let key: String
    let credentialId: String
    let kekIv: String
    let encryptedKeys: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case key
        case credentialId = "credential_id"
        case kekIv = "kek_iv"
        case encryptedKeys = "encrypted_keys"
        case idempotencyKey = "idempotency_key"
    }
}

private struct RemoveBundleRequest: Encodable {
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

private struct KeyRef: Encodable {
    let key: String
}

private struct MigrateAllRequest: Encodable {
    let keys: [KeyRef]
    let target: KeyRef
}

/// The content key registry, through the account's session. Its
/// requests carry the account's identity and never the content key
/// itself as the session's other requests do: the key, where one is
/// sent, is a member of the request.
@MainActor
final class KeyRegistry {
    static let shared = KeyRegistry()

    /// `If-Match` for a registration that must find no key.
    static let noKey = "*"

    private weak var account: HarnessAccount?

    private init() {}

    /// The account whose session the registry is read through, which
    /// changes as the account does.
    func bind(_ account: HarnessAccount?) {
        self.account = account
    }

    private func post<T: Decodable>(_ route: HarnessRoute, _ body: some Encodable) async throws -> T {
        guard let account else { throw HarnessError.unauthenticated }
        return try await account.post(route, body, keyless: true)
    }

    /// The current key and its bundles. An account without a key is an
    /// ordinary state, not a failure.
    func current() async throws -> KeyState {
        KeyState(try await post(.keysCurrent, EmptyBody()) as Components.Schemas.KeyCurrent)
    }

    /// Registers a key, as the account's first or in place of the current
    /// one, and returns its id. `ifMatch` is the current key's etag, or
    /// `noKey` for an account that must have none.
    func register(key: String, ifMatch: String, createdVia: KeyOrigin, initialBundle: KeyBundleInput? = nil) async throws -> String {
        let registered: KeyRegistered = try await post(.keysRegister, KeyRegisterRequest(
            key: key, ifMatch: ifMatch, createdVia: createdVia.rawValue, idempotencyKey: Self.idempotencyKey(), initialBundle: initialBundle
        ))
        return registered.keyId
    }

    func addBundle(keyId: String, key: String, _ bundle: KeyBundleInput) async throws {
        let _: RawJSON = try await post(.keysAddBundle, AddBundleRequest(
            keyId: keyId, key: key, credentialId: bundle.credentialId, kekIv: bundle.kekIv, encryptedKeys: bundle.encryptedKeys,
            idempotencyKey: Self.idempotencyKey()
        ))
    }

    func removeBundle(keyId: String, key: String, credentialId: String) async throws {
        let _: RawJSON = try await post(.keysRemoveBundle, RemoveBundleRequest(
            keyId: keyId, key: key, credentialId: credentialId, idempotencyKey: Self.idempotencyKey()
        ))
    }

    /// Has the harness reseal every row an older key sealed under the
    /// target, which it also registers as the current key when the account
    /// has none. The harness owns the job; its first report is returned.
    func migrateAll(keys: [String], target: String) async throws {
        let _: RawJSON = try await post(.keysMigrateAll, MigrateAllRequest(keys: keys.map(KeyRef.init), target: KeyRef(key: target)))
    }

    private static func idempotencyKey() -> String {
        UUID().uuidString.lowercased()
    }
}

extension HarnessError {
    /// The harness refused the key because the account holds another, or
    /// rows sealed under another.
    var isKeyMismatch: Bool { code == HarnessErrorCode.keyMismatch }

    /// The registry could not be reached, or refused on its own account.
    var isRegistryUnavailable: Bool {
        if let status, status >= Constants.Harness.Keys.serverErrorStatus { return true }
        return [HarnessErrorCode.connection, HarnessErrorCode.upstreamRefused, HarnessErrorCode.configuration].contains(code)
    }
}
