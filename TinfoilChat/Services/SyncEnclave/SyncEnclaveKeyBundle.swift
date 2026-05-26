//
//  SyncEnclaveKeyBundle.swift
//  TinfoilChat
//
//  Wrap / unwrap the user's content encryption key (CEK) under a
//  passkey-PRF-derived KEK, in the shape the sync enclave expects.
//
//  The enclave wire (see syncplan.md §6 and Go `internal/server/types.go`)
//  carries one wrapped CEK per registered passkey credential. There is no
//  list of "alternative" keys: the enclave is the single source of truth,
//  and legacy alternatives are handled by opportunistic migration.
//

import CryptoKit
import Foundation

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

enum SyncEnclaveKeyBundle {

    static let cekByteCount = 32
    static let aesGcmIvByteCount = 12
    static let keyIdByteCount = 16

    /// HKDF `info` string used to derive the deterministic 16-byte
    /// key_id from a raw CEK. Mirrors the Go enclave's `crypto.DeriveKeyID`
    /// byte-for-byte.
    static let keyIdInfo = Data("tinfoil-key-id-v1".utf8)

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
        guard cek.count == cekByteCount else {
            throw SyncEnclaveKeyBundleError.wrongCekLength(cek.count)
        }
        var ivBytes = [UInt8](repeating: 0, count: aesGcmIvByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
        guard status == errSecSuccess else {
            throw SyncEnclaveKeyBundleError.randomGenerationFailed(status)
        }
        let iv = Data(ivBytes)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(cek, using: kek, nonce: nonce)
        // The enclave persists kek_iv (12 B) + ciphertext + tag (16 B)
        // as separate hex strings. SealedBox.ciphertext does not include
        // the tag — we append it explicitly to match the on-wire layout.
        var ciphertextAndTag = Data(sealed.ciphertext)
        ciphertextAndTag.append(sealed.tag)
        return SyncEnclaveBundleBody(
            credentialId: credentialId,
            kekIvHex: dataToHex(iv),
            wrappedKeyHex: dataToHex(ciphertextAndTag)
        )
    }

    /// Inverse of `wrapCek`. Returns the raw 32-byte CEK from a hex
    /// IV + wrapped key ciphertext. Throws on any tamper or shape
    /// mismatch.
    static func unwrapCek(
        kek: SymmetricKey,
        kekIvHex: String,
        wrappedKeyHex: String
    ) throws -> Data {
        let iv = try hexToData(kekIvHex)
        guard iv.count == aesGcmIvByteCount else {
            throw SyncEnclaveKeyBundleError.wrongIvLength(iv.count)
        }
        let combinedCipher = try hexToData(wrappedKeyHex)
        // AES-GCM tag is 128 bits / 16 bytes.
        let tagSize = 16
        guard combinedCipher.count > tagSize else {
            throw SyncEnclaveError(message: "Wrapped CEK too short to contain tag")
        }
        let ciphertext = combinedCipher.prefix(combinedCipher.count - tagSize)
        let tag = combinedCipher.suffix(tagSize)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealed, using: kek)
        if plaintext.count == cekByteCount {
            return plaintext
        }
        // Pre-v2 webapp bundles wrap a JSON envelope around the CEK
        // instead of raw bytes. A user who registered their passkey
        // on that codepath and then signs in on iOS would otherwise
        // be stuck unable to unlock. Try to recover the primary key
        // bytes from the legacy shape before giving up.
        if let legacyCek = legacyJsonPrimaryBytes(plaintext) {
            return legacyCek
        }
        throw SyncEnclaveKeyBundleError.wrongCekLength(plaintext.count)
    }

    /// Best-effort decode of the legacy `{primary: <base64>, alternatives: [...]}`
    /// envelope the pre-v2 webapp wrapped before iOS standardised on raw CEK
    /// bytes. Returns the 32 raw CEK bytes if and only if the plaintext is
    /// well-formed JSON with a base64 `primary` field that decodes to exactly
    /// `cekByteCount`. Any deviation returns nil so the caller surfaces the
    /// original error.
    private static func legacyJsonPrimaryBytes(_ plaintext: Data) -> Data? {
        struct LegacyEnvelope: Decodable {
            let primary: String?
        }
        guard let envelope = try? JSONDecoder().decode(LegacyEnvelope.self, from: plaintext),
              let primary = envelope.primary,
              let cek = Data(base64Encoded: primary),
              cek.count == cekByteCount else {
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
        guard cek.count == cekByteCount else {
            throw SyncEnclaveKeyBundleError.wrongCekLength(cek.count)
        }
        let ikm = SymmetricKey(data: cek)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data(),
            info: keyIdInfo,
            outputByteCount: keyIdByteCount
        )
        let bytes = derived.withUnsafeBytes { Data($0) }
        return dataToHex(bytes)
    }
}
