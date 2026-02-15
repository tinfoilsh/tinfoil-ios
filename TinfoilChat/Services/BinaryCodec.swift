//
//  BinaryCodec.swift
//  TinfoilChat
//
//  Compress-then-encrypt codec for v1 chat format.
//  Uses GzipSwift for compression and CryptoKit for AES-256-GCM.
//
//  Wire format (matches React): nonce(12) || ciphertext || tag(16)
//  This is identical to CryptoKit's AES.GCM.SealedBox.combined.
//

import Foundation
import CryptoKit
import Gzip

enum BinaryCodecError: LocalizedError {
    case sealedBoxCombinedFailed
    case invalidCombinedLength

    var errorDescription: String? {
        switch self {
        case .sealedBoxCombinedFailed:
            return "AES-GCM sealed box failed to produce combined representation"
        case .invalidCombinedLength:
            return "Encrypted data too short to contain nonce and tag"
        }
    }
}

// MARK: - Chat encryption (compress-then-encrypt with shared key)

enum BinaryCodec {

    /// JSON-encode → gzip → AES-GCM encrypt.
    /// Returns the combined wire format: nonce(12) || ciphertext || tag(16).
    static func compressAndEncrypt<T: Encodable>(_ value: T, using key: SymmetricKey) throws -> Data {
        let json = try JSONEncoder().encode(value)
        let compressed = try json.gzipped()
        let sealed = try AES.GCM.seal(compressed, using: key)
        guard let combined = sealed.combined else {
            throw BinaryCodecError.sealedBoxCombinedFailed
        }
        return combined
    }

    /// AES-GCM decrypt → gunzip → JSON-decode.
    /// Expects the combined wire format: nonce(12) || ciphertext || tag(16).
    static func decryptAndDecompress<T: Decodable>(_ data: Data, using key: SymmetricKey, as type: T.Type) throws -> T {
        let raw = try decryptRaw(data, using: key)
        return try JSONDecoder().decode(type, from: raw)
    }

    /// AES-GCM decrypt → gunzip, returning raw decompressed bytes.
    static func decryptRaw(_ data: Data, using key: SymmetricKey) throws -> Data {
        let minLength = 12 + 16 // nonce + tag
        guard data.count > minLength else {
            throw BinaryCodecError.invalidCombinedLength
        }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        guard decrypted.isGzipped else {
            return decrypted
        }
        return try decrypted.gunzipped()
    }
}

// MARK: - Per-attachment encryption (random key, no compression)

extension BinaryCodec {

    struct AttachmentEncryptionResult {
        let encryptedData: Data
        /// Raw 256-bit key bytes (32 bytes)
        let key: Data
        /// Raw nonce bytes (12 bytes)
        let nonce: Data
    }

    /// Encrypt attachment data with a fresh random AES-256-GCM key.
    /// Returns the encrypted blob + the key material needed to decrypt it.
    static func encryptAttachment(_ plaintext: Data) throws -> AttachmentEncryptionResult {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let combined = sealed.combined else {
            throw BinaryCodecError.sealedBoxCombinedFailed
        }
        let keyData = key.withUnsafeBytes { Data($0) }
        let nonceData = Data(nonce)
        return AttachmentEncryptionResult(encryptedData: combined, key: keyData, nonce: nonceData)
    }

    /// Decrypt attachment data using the key material from encryptAttachment.
    /// `key` is the raw 256-bit key bytes, `encryptedData` is the combined wire format.
    static func decryptAttachment(_ encryptedData: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
}
