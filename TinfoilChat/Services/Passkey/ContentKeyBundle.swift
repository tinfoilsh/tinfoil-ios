//
//  ContentKeyBundle.swift
//  TinfoilChat
//
//  Wrap / unwrap the user's content encryption key (CEK) under a
//  passkey-PRF-derived KEK, in the shape the key registry expects.
//
//  The registry carries one wrapped CEK per registered passkey
//  credential. There is no list of "alternative" keys: the registry is
//  the single source of truth, and rows older keys sealed are resealed
//  by the chat service.
//

import CryptoKit
import Foundation

struct WrappedKeyBundle {
    /// Base64url-encoded credential id (matches WebAuthn convention).
    let credentialId: String
    /// 12-byte AES-GCM IV, hex-encoded.
    let kekIvHex: String
    /// Wrapped CEK ciphertext, hex-encoded.
    let wrappedKeyHex: String
}

enum ContentKeyBundleError: LocalizedError {
    case wrongCekLength(Int)
    case wrongIvLength(Int)
    case duplicateKey

    var errorDescription: String? {
        switch self {
        case .wrongCekLength(let got):
            return "CEK must be 32 bytes (got \(got))"
        case .wrongIvLength(let got):
            return "AES-GCM IV must be 12 bytes (got \(got))"
        case .duplicateKey:
            return "The passkey bundle names a key more than once"
        }
    }
}

/// Result of unwrapping a bundle. Besides the primary CEK, an envelope
/// (the legacy pre-v2 JSON envelope or the generic key envelope) can
/// list historical `key_<base36>` alternatives that older rows may
/// still be sealed under; callers feed those into the decrypt-only key
/// history so the migration sweep can unseal them.
struct UnwrappedContentKey {
    let cek: Data
    let legacyAlternativeKeys: [String]
}

enum ContentKeyBundle {

    static let cekByteCount = 32
    static let aesGcmIvByteCount = 12
    static let aesGcmTagByteCount = 16
    static let keyIdByteCount = 16

    /// HKDF `info` string used to derive the deterministic 16-byte
    /// key_id from a raw CEK. Mirrors the Go enclave's `crypto.DeriveKeyID`
    /// byte-for-byte.
    static let keyIdInfo = Data("tinfoil-key-id-v1".utf8)

    /// Unwrap the legacy pre-v2 JSON envelope and surface its historical
    /// alternative keys. Callers feed those into the decrypt-only key
    /// history so legacy rows can still be unsealed by the migration sweep.
    static func unwrapLegacyJsonEnvelope(
        prfOutput: Data,
        kekIvHex: String,
        wrappedKeyHex: String
    ) throws -> UnwrappedContentKey {
        guard let iv = Data(lowercaseHex: kekIvHex.lowercased()), !iv.isEmpty else {
            throw ContentKeyBundleError.wrongIvLength(kekIvHex.count / 2)
        }
        guard iv.count == aesGcmIvByteCount else {
            throw ContentKeyBundleError.wrongIvLength(iv.count)
        }
        guard let encrypted = Data(lowercaseHex: wrappedKeyHex.lowercased()), !encrypted.isEmpty else {
            throw ContentKeyBundleError.wrongCekLength(wrappedKeyHex.count / 2)
        }
        guard encrypted.count >= aesGcmTagByteCount else {
            throw ContentKeyBundleError.wrongCekLength(encrypted.count)
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: encrypted.dropLast(aesGcmTagByteCount),
            tag: encrypted.suffix(aesGcmTagByteCount)
        )
        let kek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: prfOutput),
            salt: Data(),
            info: TinfoilPasskeyProfile.hkdfInfo,
            outputByteCount: cekByteCount
        )
        let plaintext = try AES.GCM.open(sealed, using: kek)
        if let legacy = legacyJsonEnvelopeCek(plaintext) {
            return legacy
        }
        throw ContentKeyBundleError.wrongCekLength(plaintext.count)
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
    private static func legacyJsonEnvelopeCek(_ plaintext: Data) -> UnwrappedContentKey? {
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
        return UnwrappedContentKey(cek: cek, legacyAlternativeKeys: alternatives)
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

    /// Derive the user's 16-byte key_id from their raw CEK via HKDF-SHA-256
    /// with `info = "tinfoil-key-id-v1"` and an empty salt — matches the
    /// enclave's `crypto.DeriveKeyID` byte-for-byte.
    static func deriveKeyIdHex(cek: Data) throws -> String {
        guard cek.count == cekByteCount else {
            throw ContentKeyBundleError.wrongCekLength(cek.count)
        }
        let keyId = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: cek),
            salt: Data(),
            info: keyIdInfo,
            outputByteCount: keyIdByteCount
        )
        return keyId.withUnsafeBytes { Data($0).hexEncodedString() }
    }
}
