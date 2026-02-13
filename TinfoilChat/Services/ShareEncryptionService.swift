//
//  ShareEncryptionService.swift
//  TinfoilChat
//
//  Encryption service for chat sharing using AES-256-GCM + gzip.
//  Matches the React web app's share-encryption.ts implementation.
//

import Foundation
import CryptoKit
import Compression

/// Encrypted share data format matching the React EncryptedShareData type
struct EncryptedShareData: Codable {
    let v: Int      // Format version (always 1)
    let iv: String  // Base64-encoded 12-byte IV
    let ct: String  // Base64-encoded ciphertext (of gzipped JSON)
}

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
    }

    struct ShareableDocument: Codable {
        let name: String
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

    /// Encrypt data for sharing: JSON -> gzip -> AES-256-GCM
    /// Returns EncryptedShareData with base64-encoded IV and ciphertext
    static func encryptForShare(_ data: ShareableChatData, key: SymmetricKey) throws -> EncryptedShareData {
        let jsonData = try JSONEncoder().encode(data)

        guard let compressed = gzipCompress(jsonData) else {
            throw ShareEncryptionError.compressionFailed
        }

        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(compressed, using: key, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw ShareEncryptionError.encryptionFailed
        }

        // AES.GCM.seal combined = nonce (12) + ciphertext + tag (16)
        // Extract just the ciphertext+tag portion (skip the 12-byte nonce prefix)
        let ivBytes = Data(nonce.withUnsafeBytes { Data($0) })
        let ciphertextAndTag = combined.dropFirst(Constants.Share.ivByteLength)

        return EncryptedShareData(
            v: Constants.Share.formatVersion,
            iv: ivBytes.base64EncodedString(),
            ct: Data(ciphertextAndTag).base64EncodedString()
        )
    }

    // MARK: - Gzip Compression

    /// Compress data using gzip (matching pako.gzip in the React app).
    /// Produces standard RFC 1952 gzip: 10-byte header + raw deflate + CRC32 + ISIZE.
    /// Apple's COMPRESSION_ZLIB produces raw deflate (RFC 1951) which is what gzip wraps.
    private static func gzipCompress(_ data: Data) -> Data? {
        // Gzip header: magic(2) + method(1) + flags(1) + mtime(4) + xfl(1) + os(1)
        var gzipData = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])

        // Deflate the data with a generous buffer (incompressible data can expand)
        let bufferSize = data.count + data.count + 512
        var destinationBuffer = Data(count: bufferSize)

        let compressedSize: Int? = data.withUnsafeBytes { sourcePointer in
            guard let sourceBaseAddress = sourcePointer.baseAddress else { return nil }
            return destinationBuffer.withUnsafeMutableBytes { destPointer in
                guard let destBaseAddress = destPointer.baseAddress else { return nil }
                let result = compression_encode_buffer(
                    destBaseAddress.assumingMemoryBound(to: UInt8.self),
                    destPointer.count,
                    sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                return result > 0 ? result : nil
            }
        }

        guard let size = compressedSize else { return nil }
        gzipData.append(destinationBuffer.prefix(size))

        // Gzip footer: CRC32 + original size, both little-endian uint32
        var crc = crc32Checksum(data)
        gzipData.append(Data(bytes: &crc, count: 4))
        var originalSize = UInt32(data.count & 0xFFFFFFFF)
        gzipData.append(Data(bytes: &originalSize, count: 4))

        return gzipData
    }

    /// Calculate CRC32 checksum (ISO 3309 / ITU-T V.42) for gzip footer
    private static func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        let polynomial: UInt32 = 0xEDB88320

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }

        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Errors

enum ShareEncryptionError: LocalizedError {
    case compressionFailed
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "Failed to compress chat data"
        case .encryptionFailed:
            return "Failed to encrypt chat data"
        }
    }
}
