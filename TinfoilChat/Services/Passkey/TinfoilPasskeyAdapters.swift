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

        let orderedBundles: [KeyState.Bundle]
        let current: [Current]
        let legacy: [KeyState.Bundle]

        enum Selection {
            case current(Current)
            case legacy(KeyState.Bundle)
            case missing
        }

        var credentialIds: [String] {
            orderedBundles.map(\.credentialId)
        }

        func current(credentialId: String) -> Current? {
            current.first { $0.bundle.credentialId == credentialId }
        }

        func legacy(credentialId: String) -> KeyState.Bundle? {
            legacy.first { $0.credentialId == credentialId }
        }

        func selection(credentialId: String) -> Selection {
            if let current = current(credentialId: credentialId) {
                return .current(current)
            }
            if let legacy = legacy(credentialId: credentialId) {
                return .legacy(legacy)
            }
            return .missing
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
        var legacy: [KeyState.Bundle] = []
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
            } else {
                legacy.append(bundle)
            }
        }
        return CandidateSet(
            orderedBundles: orderedBundles,
            current: current,
            legacy: legacy
        )
    }
}

/// Decodes pre-kit PRF cache formats. Passed to the kit's Keychain
/// storage adapter as its `decodeCachedRecord` fallback, which runs
/// only when the stored payload is not a canonical `CachedPRFResult`.
enum TinfoilPasskeyCacheMigration {
    private struct LegacyCacheEntry: Codable {
        let credentialId: String
        let prfOutput: Data
        let isPlatformAuthenticator: Bool?
    }

    private struct PreviousCacheEntry: Codable {
        struct Profile: Codable {
            let version: Int
            let relyingPartyId: String
            let relyingPartyName: String
            let prfSalt: Data
            let hkdfInfo: Data
        }

        let profile: Profile
        let credentialId: String
        let prfOutput: Data
    }

    static func decodeCachedRecord(_ data: Data) throws -> CachedPRFResult {
        if let previous = try? JSONDecoder().decode(PreviousCacheEntry.self, from: data) {
            guard previous.profile.version == TinfoilPasskeyProfile.version,
                  previous.profile.relyingPartyId == Constants.Passkey.rpId,
                  previous.profile.relyingPartyName == Constants.Passkey.rpName,
                  previous.profile.prfSalt == TinfoilPasskeyProfile.prfSalt,
                  previous.profile.hkdfInfo == TinfoilPasskeyProfile.hkdfInfo else {
                throw PasskeyKeyError.invalidInput(
                    diagnostic: "cached passkey profile mismatch"
                )
            }
            return CachedPRFResult(
                profile: TinfoilPasskeyProfile.current,
                credentialId: previous.credentialId,
                prfOutput: previous.prfOutput
            )
        }
        let legacy = try JSONDecoder().decode(LegacyCacheEntry.self, from: data)
        return CachedPRFResult(
            profile: TinfoilPasskeyProfile.current,
            credentialId: legacy.credentialId,
            prfOutput: legacy.prfOutput
        )
    }

    @MainActor
    static func makeStorage() -> KeychainPasskeyKeyStorage {
        KeychainPasskeyKeyStorage(
            service: Constants.Passkey.rpId,
            account: Constants.Passkey.prfCacheKeychainAccount,
            localCredentialIdKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId,
            decodeCachedRecord: decodeCachedRecord
        )
    }
}
