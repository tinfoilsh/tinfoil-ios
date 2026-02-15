//
//  ShareEncryptionService.swift
//  TinfoilChat
//
//  Encryption service for chat sharing using AES-256-GCM + gzip.
//  Matches the React web app's share-encryption.ts implementation.
//

import Foundation
import CryptoKit

/// Shareable chat data structure matching React's ShareableChatData type
struct ShareableChatData: Codable {
    let v: Int
    let title: String
    let messages: [ShareableMessage]
    let createdAt: Double // Epoch milliseconds

    struct ShareableMessage: Codable {
        let role: String
        let content: String
        let documentContent: String?
        let documents: [ShareableDocument]?
        let timestamp: Double // Epoch milliseconds
        let thoughts: String?
        let thinkingDuration: Double?
        let isError: Bool?
        let attachments: [ShareableAttachment]?
    }

    struct ShareableDocument: Codable {
        let name: String
    }

    struct ShareableAttachment: Codable {
        let id: String
        let type: String
        let fileName: String
        let mimeType: String?
        let thumbnailBase64: String?
        let encryptionKey: String?
        let textContent: String?
        let description: String?
    }
}

/// Service for handling share-specific encryption
enum ShareEncryptionService {

    // MARK: - Key Generation

    /// Generate a throwaway AES-256 symmetric key for share encryption
    static func generateShareKey() -> SymmetricKey {
        return SymmetricKey(size: .bits256)
    }

    // MARK: - Key Export / Import

    /// Export a SymmetricKey to base64url string (for URL fragment)
    static func exportKeyToBase64url(_ key: SymmetricKey) -> String {
        let keyData = key.withUnsafeBytes { Data($0) }
        let base64 = keyData.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Encryption

    /// Encrypt data for sharing using v1 binary format: JSON -> gzip -> AES-256-GCM.
    /// Returns raw binary (nonce + ciphertext + tag).
    static func encryptForShare(_ data: ShareableChatData, key: SymmetricKey) throws -> Data {
        return try BinaryCodec.compressAndEncrypt(data, using: key)
    }
}
