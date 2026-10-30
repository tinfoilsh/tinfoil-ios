import Foundation
import TinfoilPasskeyKit

enum TinfoilPasskeyProfile {
    static let version = 1
    static let prfSalt = Data("tinfoil-chat-key-encryption".utf8)
    static let hkdfInfo = Data("tinfoil-chat-kek-v1".utf8)

    static let current = try! PasskeyKeyProfile(
        version: version,
        relyingPartyId: Constants.Passkey.rpId,
        prfSalt: prfSalt,
        hkdfInfo: hkdfInfo
    )
}

enum TinfoilWrappedKeyAdapter {
    struct EnclaveFields: Equatable {
        let credentialId: String
        let kekIvHex: String
        let wrappedKeyHex: String
    }

    struct CandidateSet {
        struct Current {
            let bundle: KeyState.Bundle
            let wrappedKey: WrappedKey
        }

        let current: [Current]

        var credentialIds: [String] {
            current.map(\.bundle.credentialId)
        }

        func current(credentialId: String) -> Current? {
            current.first { $0.bundle.credentialId == credentialId }
        }
    }

    static func wrappedKey(_ fields: EnclaveFields) -> WrappedKey {
        WrappedKey(
            profile: TinfoilPasskeyProfile.current,
            credentialId: fields.credentialId,
            kekIvHex: fields.kekIvHex,
            wrappedKeyHex: fields.wrappedKeyHex
        )
    }

    static func enclaveFields(_ wrappedKey: WrappedKey) -> EnclaveFields {
        EnclaveFields(
            credentialId: wrappedKey.credentialId,
            kekIvHex: wrappedKey.kekIvHex,
            wrappedKeyHex: wrappedKey.wrappedKeyHex
        )
    }

    static func bundleBody(_ wrappedKey: WrappedKey) -> WrappedKeyBundle {
        let fields = enclaveFields(wrappedKey)
        return WrappedKeyBundle(
            credentialId: fields.credentialId,
            kekIvHex: fields.kekIvHex,
            wrappedKeyHex: fields.wrappedKeyHex
        )
    }

    static func partition(
        _ bundles: [KeyState.Bundle],
        preferredCredentialId: String?
    ) -> CandidateSet {
        let orderedBundles: [KeyState.Bundle]
        guard let preferredCredentialId,
              bundles.contains(where: { $0.credentialId == preferredCredentialId }) else {
            return candidateSet(orderedBundles: bundles)
        }
        orderedBundles = bundles.filter { $0.credentialId == preferredCredentialId }
            + bundles.filter { $0.credentialId != preferredCredentialId }
        return candidateSet(orderedBundles: orderedBundles)
    }

    private static func candidateSet(
        orderedBundles: [KeyState.Bundle]
    ) -> CandidateSet {
        var current: [CandidateSet.Current] = []
        for bundle in orderedBundles {
            if bundle.kekIv.count == ContentKeyBundle.aesGcmIvByteCount * 2,
               bundle.encryptedKeys.count == (
                   ContentKeyBundle.cekByteCount + ContentKeyBundle.aesGcmTagByteCount
               ) * 2 {
                current.append(CandidateSet.Current(
                    bundle: bundle,
                    wrappedKey: wrappedKey(EnclaveFields(
                        credentialId: bundle.credentialId,
                        kekIvHex: bundle.kekIv,
                        wrappedKeyHex: bundle.encryptedKeys
                    ))
                ))
            }
        }
        return CandidateSet(current: current)
    }
}

/// What the passkey kit keeps on this device: only the id of the passkey
/// made here, which the recovery prompt offers first. The PRF output a
/// ceremony returns is never kept, as it would unwrap the content key
/// without the passkey.
@MainActor
final class LocalCredentialPasskeyStorage: PasskeyKeyStorage {
    private let defaults: UserDefaults
    private let credentialIdKey: String

    init(defaults: UserDefaults = .standard, credentialIdKey: String = Constants.StorageKeys.Secret.passkeyEnclaveCredentialId) {
        self.defaults = defaults
        self.credentialIdKey = credentialIdKey
    }

    func loadCachedPRFResult() throws -> CachedPRFResult? { nil }

    func saveCachedPRFResult(_ result: CachedPRFResult) throws {}

    func loadLocalCredentialId() throws -> String? {
        defaults.string(forKey: credentialIdKey)
    }

    func saveLocalCredentialId(_ credentialId: String) throws {
        defaults.set(credentialId, forKey: credentialIdKey)
    }

    func clear() throws {
        defaults.removeObject(forKey: credentialIdKey)
    }
}
