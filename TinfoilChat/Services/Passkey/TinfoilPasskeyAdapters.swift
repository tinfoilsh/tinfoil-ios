import Foundation
import Security
import TinfoilPasskeyKit

enum TinfoilPasskeyProfile {
    static let version = 1
    static let prfSalt = Data("tinfoil-chat-key-encryption".utf8)
    static let hkdfInfo = Data("tinfoil-chat-kek-v1".utf8)

    static let current = try! PasskeyKeyProfile(
        version: version,
        relyingPartyId: Constants.Passkey.rpId,
        relyingPartyName: Constants.Passkey.rpName,
        prfSalt: prfSalt,
        hkdfInfo: hkdfInfo
    )
}

enum TinfoilWrappedKeyAdapter {
    static func wrappedKey(
        credentialId: String,
        kekIvHex: String,
        wrappedKeyHex: String
    ) -> WrappedKey {
        WrappedKey(
            profile: TinfoilPasskeyProfile.current,
            credentialId: credentialId,
            kekIvHex: kekIvHex,
            wrappedKeyHex: wrappedKeyHex
        )
    }

    static func bundleBody(_ wrappedKey: WrappedKey) -> SyncEnclaveBundleBody {
        SyncEnclaveBundleBody(
            credentialId: wrappedKey.credentialId,
            kekIvHex: wrappedKey.kekIvHex,
            wrappedKeyHex: wrappedKey.wrappedKeyHex
        )
    }

    static func ordered(
        _ wrappedKeys: [WrappedKey],
        preferredCredentialId: String?
    ) -> [WrappedKey] {
        guard let preferredCredentialId,
              wrappedKeys.contains(where: { $0.credentialId == preferredCredentialId }) else {
            return wrappedKeys
        }
        return wrappedKeys.filter { $0.credentialId == preferredCredentialId }
            + wrappedKeys.filter { $0.credentialId != preferredCredentialId }
    }
}

@MainActor
final class TinfoilPasskeyKeyStorage: PasskeyKeyStorage {
    private struct LegacyCacheEntry: Codable {
        let credentialId: String
        let prfOutput: Data
        let isPlatformAuthenticator: Bool?
    }

    private let service: String
    private let account: String
    private let localCredentialIdKey: String
    private let userDefaults: UserDefaults

    init(
        service: String = Constants.Passkey.rpId,
        account: String = Constants.Passkey.prfCacheKeychainAccount,
        localCredentialIdKey: String = Constants.StorageKeys.Secret.passkeyEnclaveCredentialId,
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.account = account
        self.localCredentialIdKey = localCredentialIdKey
        self.userDefaults = userDefaults
    }

    func loadCachedPRFResult() throws -> CachedPRFResult? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var value: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw storageError(status)
        }
        return try Self.decodeCachedRecord(data)
    }

    func saveCachedPRFResult(_ result: CachedPRFResult) throws {
        let data = try JSONEncoder().encode(result)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw storageError(updateStatus)
        }

        var query = baseQuery
        attributes.forEach { query[$0.key] = $0.value }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw storageError(addStatus)
        }
    }

    func loadLocalCredentialId() throws -> String? {
        userDefaults.string(forKey: localCredentialIdKey)
    }

    func saveLocalCredentialId(_ credentialId: String) throws {
        userDefaults.set(credentialId, forKey: localCredentialIdKey)
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw storageError(status)
        }
        userDefaults.removeObject(forKey: localCredentialIdKey)
    }

    static func decodeCachedRecord(_ data: Data) throws -> CachedPRFResult {
        if let current = try? JSONDecoder().decode(CachedPRFResult.self, from: data) {
            return current
        }
        let legacy = try JSONDecoder().decode(LegacyCacheEntry.self, from: data)
        return CachedPRFResult(
            profile: TinfoilPasskeyProfile.current,
            credentialId: legacy.credentialId,
            prfOutput: legacy.prfOutput
        )
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func storageError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil)
                    ?? "Passkey storage failed" as CFString
            ]
        )
    }
}
