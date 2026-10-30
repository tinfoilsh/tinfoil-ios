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

    var errorDescription: String? {
        switch self {
        case .wrongCekLength(let got):
            return "CEK must be 32 bytes (got \(got))"
        }
    }
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
