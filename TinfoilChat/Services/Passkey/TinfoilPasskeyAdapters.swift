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
        /// A bundle the kit unwraps: one wrapped key, or a generic key
        /// envelope's primary key with the alternatives wrapped beside it.
        struct Current {
            let bundle: KeyState.Bundle
            let wrappedKey: WrappedKey
            var alternatives: [WrappedKey] = []
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
        var usable: [KeyState.Bundle] = []
        var current: [CandidateSet.Current] = []
        var legacy: [KeyState.Bundle] = []
        for bundle in orderedBundles {
            switch GenericKeyEnvelope.parse(bundle) {
            case .envelope(let primary, let alternatives):
                usable.append(bundle)
                current.append(CandidateSet.Current(bundle: bundle, wrappedKey: primary, alternatives: alternatives))
                continue
            case .invalid:
                continue
            case .notEnvelope:
                usable.append(bundle)
            }
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
            orderedBundles: usable,
            current: current,
            legacy: legacy
        )
    }
}

/// The generic key envelope web clients write into a bundle's
/// `encrypted_keys`: plaintext UTF-8 JSON naming the primary key and its
/// alternatives as the kit's wrapped key records, each wrapped under the
/// bundle's own passkey.
enum GenericKeyEnvelope {
    static let version = 1
    static let maxAlternatives = 64
    static let maxBytes = 128 * 1024
    static let authorizationModes: Set<String> = ["validated", "explicit_start_fresh"]
    private static let fields: Set<String> = ["version", "authorizationMode", "primary", "alternatives"]
    private static let objectStart: Character = "{"

    enum Parsed {
        /// The bundle carries a single wrapped key or the legacy encrypted
        /// envelope.
        case notEnvelope
        /// The bundle carries an envelope that fails its checks, and is not
        /// a candidate.
        case invalid
        case envelope(primary: WrappedKey, alternatives: [WrappedKey])
    }

    static func parse(_ bundle: KeyState.Bundle) -> Parsed {
        guard let bytes = Data(lowercaseHex: bundle.encryptedKeys),
              bytes.count <= maxBytes,
              let text = String(data: bytes, encoding: .utf8),
              text.drop(while: \.isWhitespace).first == objectStart else {
            return .notEnvelope
        }
        guard Data(lowercaseHex: bundle.kekIv)?.count == ContentKeyBundle.aesGcmIvByteCount,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              Set(object.keys) == fields,
              let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version == NSNumber(value: Self.version),
              let mode = object["authorizationMode"] as? String, authorizationModes.contains(mode),
              let primaryRecord = object["primary"] as? String,
              let alternativeRecords = object["alternatives"] as? [String],
              alternativeRecords.count <= maxAlternatives,
              Set(alternativeRecords).count == alternativeRecords.count,
              !alternativeRecords.contains(primaryRecord),
              let primary = canonicalRecord(primaryRecord) else {
            return .invalid
        }
        var alternatives: [WrappedKey] = []
        for record in alternativeRecords {
            guard let alternative = canonicalRecord(record) else { return .invalid }
            alternatives.append(alternative)
        }
        let records = [primary] + alternatives
        guard records.allSatisfy({ $0.profile == TinfoilPasskeyProfile.current && $0.credentialId == bundle.credentialId }),
              Set(records.map(\.kekIvHex)).count == records.count else {
            return .invalid
        }
        return .envelope(primary: primary, alternatives: alternatives)
    }

    /// A wrapped key record the kit decodes and encodes back to the same
    /// bytes.
    private static func canonicalRecord(_ record: String) -> WrappedKey? {
        let data = Data(record.utf8)
        guard let wrappedKey = try? decodeWrappedKeyRecord(data),
              (try? encodeWrappedKeyRecord(wrappedKey)) == data else {
            return nil
        }
        return wrappedKey
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
