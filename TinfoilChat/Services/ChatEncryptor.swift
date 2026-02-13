//
//  ChatEncryptor.swift
//  TinfoilChat
//
//  Protocol for encrypting/decrypting raw data.
//  Implemented by DeviceEncryptionService (local chats) and EncryptionService (cloud chats).
//

import Foundation
import CryptoKit

protocol ChatEncryptor: Sendable {
    /// Encrypt raw data bytes, returning an EncryptedData envelope.
    func encryptData(_ data: Data) async throws -> EncryptedData

    /// Decrypt an EncryptedData envelope, returning the original raw data bytes.
    func decryptData(_ encrypted: EncryptedData) async throws -> Data
}

// MARK: - Shared AES-GCM helpers

/// Single-source-of-truth for the byte-level AES-GCM seal/open operations
/// used by both DeviceEncryptionService and EncryptionService.
enum AESGCMHelper {
    static func seal(_ data: Data, using key: SymmetricKey) throws -> EncryptedData {
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        var combined = Data()
        combined.append(sealedBox.ciphertext)
        combined.append(sealedBox.tag)

        return EncryptedData(
            iv: Data(nonce).base64EncodedString(),
            data: combined.base64EncodedString()
        )
    }

    static func parseSealedBox(from encrypted: EncryptedData) throws -> AES.GCM.SealedBox {
        guard let ivData = Data(base64Encoded: encrypted.iv),
              let combinedData = Data(base64Encoded: encrypted.data) else {
            throw EncryptionError.invalidBase64
        }

        // GCM tag is always 128 bits (16 bytes)
        let tagSize = 16
        guard combinedData.count > tagSize else {
            throw EncryptionError.invalidEncryptedData
        }

        let nonce = try AES.GCM.Nonce(data: ivData)
        let ciphertext = combinedData.prefix(combinedData.count - tagSize)
        let tag = combinedData.suffix(tagSize)
        return try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    }

    static func open(_ encrypted: EncryptedData, using key: SymmetricKey) throws -> Data {
        let sealedBox = try parseSealedBox(from: encrypted)
        return try AES.GCM.open(sealedBox, using: key)
    }
}
