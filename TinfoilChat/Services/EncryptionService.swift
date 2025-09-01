//
//  EncryptionService.swift
//  TinfoilChat
//
//  Encryption service for end-to-end encryption of chat data
//

import Foundation
import CryptoKit
import Security

/// Represents encrypted data with initialization vector
struct EncryptedData: Codable {
    let iv: String  // Base64 encoded initialization vector
    let data: String  // Base64 encoded encrypted data
}

/// Service for handling end-to-end encryption of chat data
class EncryptionService: ObservableObject {
    static let shared = EncryptionService()
    
    private let keychainKey = "sh.tinfoil.encryptionKey"
    private let keychainService = "sh.tinfoil.chat"
    private var encryptionKey: SymmetricKey?
    
    private init() {}
    
    // MARK: - Key Generation and Management
    
    /// Generate a new encryption key
    func generateKey() -> String {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        
        // Convert to alphanumeric format with key_ prefix (matching React format)
        return "key_" + bytesToAlphanumeric(keyData)
    }
    
    /// Initialize with existing key or generate new one
    func initialize() async throws -> String {
        // Check if this is a fresh install by looking for a first launch marker
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        
        if !hasLaunchedBefore {
            // First launch after install - clear any lingering keychain data
            deleteKeyFromKeychain()
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
        
        // Check if we have a stored key in Keychain
        if let storedKey = loadKeyFromKeychain() {
            try await setKey(storedKey)
            return storedKey
        } else {
            // Generate new key
            let newKey = generateKey()
            try saveKeyToKeychain(newKey)
            try await setKey(newKey)
            return newKey
        }
    }
    
    /// Set encryption key from alphanumeric string
    func setKey(_ keyString: String) async throws {
        var processedKey = keyString
        
        // Check if the key has the prefix
        if keyString.hasPrefix("key_") {
            processedKey = String(keyString.dropFirst(4))
        } else {
            throw EncryptionError.invalidKeyFormat
        }
        
        // Validate that the key only contains allowed characters after prefix
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if processedKey.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
            throw EncryptionError.invalidKeyCharacters
        }
        
        // Convert alphanumeric to bytes
        let keyData = try alphanumericToBytes(processedKey)
        
        // Create SymmetricKey
        self.encryptionKey = SymmetricKey(data: keyData)
        
        // Store the key in Keychain with prefix
        try saveKeyToKeychain(keyString)
    }
    
    /// Get current encryption key as alphanumeric string
    func getKey() -> String? {
        return loadKeyFromKeychain()
    }
    
    /// Remove encryption key
    func clearKey() {
        encryptionKey = nil
        deleteKeyFromKeychain()
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt data
    func encrypt<T: Encodable>(_ data: T) async throws -> EncryptedData {
        guard let encryptionKey = encryptionKey else {
            throw EncryptionError.keyNotInitialized
        }
        
        // Convert data to JSON
        let encoder = JSONEncoder()
        // Don't set date encoding - let StoredChat handle its own format
        // encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(data)
        
        // Generate random nonce (IV)
        let nonce = AES.GCM.Nonce()
        
        // Encrypt
        let sealedBox = try AES.GCM.seal(jsonData, using: encryptionKey, nonce: nonce)
        
        // Extract ciphertext and tag
        let ciphertext = sealedBox.ciphertext
        let tag = sealedBox.tag
        
        // Combine ciphertext and tag
        var combinedData = Data()
        combinedData.append(ciphertext)
        combinedData.append(tag)
        
        // Convert to base64
        let ivBase64 = Data(nonce).base64EncodedString()
        let dataBase64 = combinedData.base64EncodedString()
        
        return EncryptedData(iv: ivBase64, data: dataBase64)
    }
    
    /// Decrypt data
    func decrypt<T: Decodable>(_ encryptedData: EncryptedData, as type: T.Type) async throws -> T {
        guard let encryptionKey = encryptionKey else {
            throw EncryptionError.keyNotInitialized
        }
        
        // Validate input data
        guard !encryptedData.iv.isEmpty, !encryptedData.data.isEmpty else {
            throw EncryptionError.invalidEncryptedData
        }
        
        // Convert base64 back to data
        guard let ivData = Data(base64Encoded: encryptedData.iv),
              let combinedData = Data(base64Encoded: encryptedData.data) else {
            throw EncryptionError.invalidBase64
        }
        
        // Create nonce from IV
        let nonce = try AES.GCM.Nonce(data: ivData)
        
        // Split combined data into ciphertext and tag
        let tagSize = 16 // GCM tag is always 128 bits
        guard combinedData.count > tagSize else {
            throw EncryptionError.invalidEncryptedData
        }
        
        let ciphertext = combinedData.prefix(combinedData.count - tagSize)
        let tag = combinedData.suffix(tagSize)
        
        // Create sealed box
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        
        // Decrypt
        let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
        
        // Decode JSON
        let decoder = JSONDecoder()
        // Don't set date decoding - let StoredChat handle its own format
        // decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: decryptedData)
    }
    
    // MARK: - Helper Methods
    
    /// Convert bytes to alphanumeric string (a-z, 0-9)
    private func bytesToAlphanumeric(_ data: Data) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var result = ""
        
        for byte in data {
            result.append(chars[Int(byte / UInt8(chars.count))])
            result.append(chars[Int(byte % UInt8(chars.count))])
        }
        
        return result
    }
    
    /// Convert alphanumeric string back to bytes
    private func alphanumericToBytes(_ str: String) throws -> Data {
        // Validate input length is even (required for proper decoding)
        guard str.count % 2 == 0 else {
            throw EncryptionError.invalidKeyLength
        }
        
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = Data()
        
        let characters = Array(str)
        for i in stride(from: 0, to: characters.count, by: 2) {
            guard let highIndex = chars.firstIndex(of: characters[i]),
                  let lowIndex = chars.firstIndex(of: characters[i + 1]) else {
                throw EncryptionError.invalidKeyCharacters
            }
            
            // Validate that the combined value doesn't exceed UInt8 max (255)
            let combinedValue = highIndex * chars.count + lowIndex
            guard combinedValue <= 255 else {
                throw EncryptionError.invalidKeyCharacters
            }
            
            let byte = UInt8(combinedValue)
            bytes.append(byte)
        }
        
        return bytes
    }
    
    // MARK: - Keychain Management
    
    private func saveKeyToKeychain(_ key: String) throws {
        let data = key.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }
    }
    
    private func loadKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        
        return nil
    }
    
    private func deleteKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKey
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Encryption Errors

enum EncryptionError: LocalizedError {
    case keyNotInitialized
    case invalidKeyFormat
    case invalidKeyCharacters
    case invalidKeyLength
    case encryptionFailed
    case decryptionFailed
    case invalidEncryptedData
    case invalidBase64
    case keychainSaveFailed(status: OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .keyNotInitialized:
            return "Encryption key not initialized"
        case .invalidKeyFormat:
            return "Key must start with 'key_' prefix"
        case .invalidKeyCharacters:
            return "Key must only contain lowercase letters and numbers after the prefix"
        case .invalidKeyLength:
            return "Key length must be even"
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data"
        case .invalidEncryptedData:
            return "Missing IV or data in encrypted data"
        case .invalidBase64:
            return "Invalid base64 encoding"
        case .keychainSaveFailed(let status):
            return "Failed to save encryption key to keychain (error: \(status))"
        }
    }
}