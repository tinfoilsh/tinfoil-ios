//
//  SyncEnclaveKeyBundle.swift
//  TinfoilChat
//
//  Wrap / unwrap the user's content encryption key (CEK) under a
//  passkey-PRF-derived KEK, in the shape the sync enclave expects.
//
//  The enclave wire (Go `internal/server/types.go`) carries one wrapped
//  CEK per registered passkey credential. There is no
//  list of "alternative" keys: the enclave is the single source of truth,
//  and legacy alternatives are handled by opportunistic migration.
//

import CryptoKit
import Foundation
import TinfoilPasskeyKit

struct SyncEnclaveBundleBody {
    /// Base64url-encoded credential id (matches WebAuthn convention).
    let credentialId: String
    /// 12-byte AES-GCM IV, hex-encoded.
    let kekIvHex: String
    /// Wrapped CEK ciphertext, hex-encoded.
    let wrappedKeyHex: String
}

enum SyncEnclaveKeyBundleError: LocalizedError {
    case wrongCekLength(Int)
    case wrongIvLength(Int)
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .wrongCekLength(let got):
            return "CEK must be 32 bytes (got \(got))"
        case .wrongIvLength(let got):
            return "AES-GCM IV must be 12 bytes (got \(got))"
        case .randomGenerationFailed(let status):
            return "Secure random generation failed (status \(status))"
        }
    }
}

/// Result of unwrapping a bundle that turned out to carry the legacy
/// pre-v2 JSON envelope instead of raw CEK bytes. Besides the primary
/// CEK, the envelope can list historical `key_<base36>` alternatives
/// that older rows may still be sealed under; callers feed those into
/// the decrypt-only key history so the migration sweep can unseal them.
struct SyncEnclaveUnwrappedCek {
    let cek: Data
    let legacyAlternativeKeys: [String]
}

enum SyncEnclaveKeyBundle {

    static let cekByteCount = PasskeyProtocol.cekByteCount
    static let aesGcmIvByteCount = PasskeyProtocol.aesGCMIVByteCount
    static let keyIdByteCount = PasskeyProtocol.keyIDByteCount

    /// HKDF `info` string used to derive the deterministic 16-byte
    /// key_id from a raw CEK. Mirrors the Go enclave's `crypto.DeriveKeyID`
    /// byte-for-byte.
    static let keyIdInfo = PasskeyProtocol.tinfoilKeyIDInfoV1

    /// Wrap a raw 32-byte CEK under a passkey-PRF-derived KEK via
    /// AES-256-GCM. Returns hex-encoded IV + wrapped key in the shape
    /// the enclave expects in a register-key / add-bundle body.
    ///
    /// Callers MUST already have run the PRF flow and derived the KEK
    /// via `PasskeyService.deriveKeyEncryptionKey`.
    static func wrapCek(
        credentialId: String,
        kek: SymmetricKey,
        cek: Data
    ) throws -> SyncEnclaveBundleBody {
        do {
            let wrapped = try PasskeyCrypto.wrapCEK(
                credentialId: credentialId,
                kek: kek,
                cek: cek
            )
            return SyncEnclaveBundleBody(
                credentialId: wrapped.credentialId,
                kekIvHex: wrapped.kekIvHex,
                wrappedKeyHex: wrapped.wrappedKeyHex
            )
        } catch let error as PasskeyCryptoError {
            switch error {
            case .wrongCEKLength(let count):
                throw SyncEnclaveKeyBundleError.wrongCekLength(count)
            case .randomGenerationFailed(let status):
                throw SyncEnclaveKeyBundleError.randomGenerationFailed(status)
            default:
                throw error
            }
        }
    }

    /// Inverse of `wrapCek`. Returns the raw 32-byte CEK from a hex
    /// IV + wrapped key ciphertext. Throws on any tamper or shape
    /// mismatch.
    static func unwrapCek(
        kek: SymmetricKey,
        kekIvHex: String,
        wrappedKeyHex: String
    ) throws -> Data {
        return try unwrapCekDetailed(
            kek: kek,
            kekIvHex: kekIvHex,
            wrappedKeyHex: wrappedKeyHex
        ).cek
    }

    /// Like `unwrapCek`, but also surfaces the historical alternative
    /// keys carried by the legacy pre-v2 JSON envelope (empty for v2
    /// raw-CEK bundles). Callers on the recovery path feed those into
    /// the decrypt-only key history so legacy rows sealed under
    /// rotated-away CEKs can still be unsealed by the migration sweep.
    static func unwrapCekDetailed(
        kek: SymmetricKey,
        kekIvHex: String,
        wrappedKeyHex: String
    ) throws -> SyncEnclaveUnwrappedCek {
        let plaintext: Data
        do {
            plaintext = try PasskeyCrypto.decryptWrappedPayload(
                WrappedCEK(
                    credentialId: "",
                    kekIvHex: kekIvHex,
                    wrappedKeyHex: wrappedKeyHex
                ),
                using: kek
            )
        } catch PasskeyCryptoError.wrongIVLength(let count) {
            throw SyncEnclaveKeyBundleError.wrongIvLength(count)
        }
        if plaintext.count == cekByteCount {
            return SyncEnclaveUnwrappedCek(cek: plaintext, legacyAlternativeKeys: [])
        }
        // Pre-v2 bundles (webapp and iOS alike) wrap a JSON envelope
        // around the CEK instead of raw bytes. A user who registered
        // their passkey on that codepath and then signs in on iOS
        // would otherwise be stuck unable to unlock. Try to recover
        // the primary key bytes from the legacy shape before giving up.
        if let legacy = legacyJsonEnvelopeCek(plaintext) {
            return legacy
        }
        throw SyncEnclaveKeyBundleError.wrongCekLength(plaintext.count)
    }

    /// Best-effort decode of the legacy `{primary, alternatives: [...]}`
    /// envelope wrapped before clients standardised on raw CEK bytes.
    /// `primary` is the `key_<base36>` string every pre-v2 client stored
    /// (the same codec `EncryptionService` uses for the Keychain); some
    /// very early builds used base64, so that is tried as a fallback.
    /// Returns the 32 raw CEK bytes plus any well-formed alternatives,
    /// or nil so the caller surfaces the original error.
    ///
    /// Alternatives are re-encoded into the canonical `key_<base36>`
    /// shape regardless of which legacy format carried them: the key
    /// history they feed (`addDecryptionKey`) only accepts that shape
    /// and would silently drop a raw base64 string, stranding any
    /// legacy row still sealed under it.
    private static func legacyJsonEnvelopeCek(_ plaintext: Data) -> SyncEnclaveUnwrappedCek? {
        struct LegacyEnvelope: Decodable {
            let primary: String?
            let alternatives: [String]?
        }
        guard let envelope = try? JSONDecoder().decode(LegacyEnvelope.self, from: plaintext),
              let primary = envelope.primary,
              let cek = legacyKeyStringBytes(primary) else {
            return nil
        }
        let primaryNormalized = EncryptionService.shared.encodeKeyFromBytes(cek)
        var seen = Set<String>()
        var alternatives: [String] = []
        for alternative in envelope.alternatives ?? [] {
            guard let bytes = legacyKeyStringBytes(alternative) else { continue }
            let normalized = EncryptionService.shared.encodeKeyFromBytes(bytes)
            guard normalized != primaryNormalized, seen.insert(normalized).inserted else { continue }
            alternatives.append(normalized)
        }
        return SyncEnclaveUnwrappedCek(cek: cek, legacyAlternativeKeys: alternatives)
    }

    /// Decode one legacy envelope key string to raw CEK bytes.
    /// Accepts the canonical `key_<base36>` shape and falls back to
    /// base64 for the earliest envelope format.
    private static func legacyKeyStringBytes(_ keyString: String) -> Data? {
        if keyString.hasPrefix("key_") {
            guard let bytes = try? EncryptionService.shared.getAlternativeKeyBytes(keyString),
                  bytes.count == cekByteCount else {
                return nil
            }
            return bytes
        }
        guard let cek = Data(base64Encoded: keyString), cek.count == cekByteCount else {
            return nil
        }
        return cek
    }

    /// Convenience overload accepting a pre-built `EnclaveKeyCurrentBundle`.
    static func unwrapCek(
        kek: SymmetricKey,
        bundle: EnclaveKeyCurrentBundle
    ) throws -> Data {
        return try unwrapCek(
            kek: kek,
            kekIvHex: bundle.kekIv,
            wrappedKeyHex: bundle.encryptedKeys
        )
    }

    /// Derive the user's 16-byte key_id from their raw CEK via HKDF-SHA-256
    /// with `info = "tinfoil-key-id-v1"` and an empty salt — matches the
    /// enclave's `crypto.DeriveKeyID` byte-for-byte.
    static func deriveKeyIdHex(cek: Data) throws -> String {
        do {
            return PasskeyCodec.hexEncode(
                try PasskeyCrypto.deriveKeyID(
                    from: cek,
                    info: keyIdInfo,
                    outputByteCount: keyIdByteCount
                )
            )
        } catch PasskeyCryptoError.wrongCEKLength(let count) {
            throw SyncEnclaveKeyBundleError.wrongCekLength(count)
        }
    }
}
