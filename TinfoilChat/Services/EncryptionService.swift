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

/// Represents the result of a decryption attempt
struct DecryptionResult<T> {
    let value: T
    let usedFallbackKey: Bool
}

/// Service for handling end-to-end encryption of chat data
class EncryptionService: ObservableObject, @unchecked Sendable {
    static let shared = EncryptionService()

    private let keychainKey = "sh.tinfoil.encryptionKey"
    private let keychainService = "sh.tinfoil.chat"
    private let keychainHistoryKey = "key_history"
    private let encryptionKeySetupFlagKey = "encryptionKeyWasSetUp"
    private var _encryptionKey: SymmetricKey?
    private let keychainLock = NSLock()

    /// Thread-safe access to the in-memory encryption key.
    private var encryptionKey: SymmetricKey? {
        get { keychainLock.withLock { _encryptionKey } }
        set { keychainLock.withLock { _encryptionKey = newValue } }
    }

    private init() {}

    // MARK: - Key Generation and Management

    /// Generate a new encryption key
    func generateKey() -> String {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Convert to alphanumeric format with key_ prefix (matching React format)
        return "key_" + bytesToAlphanumeric(keyData)
    }

    /// Initialize with existing key (does NOT generate new keys)
    func initialize() async throws -> String {
        // Check if we have a stored key in Keychain
        guard let storedKey = loadKeyFromKeychain() else {
            throw EncryptionError.keyNotInitialized
        }

        try await setKey(storedKey)
        return storedKey
    }

    /// Generate and save a new encryption key for first-time setup
    func generateAndSaveNewKey() async throws -> String {
        let newKey = generateKey()
        try await setKey(newKey)
        return newKey
    }

    /// Set encryption key from alphanumeric string
    func setKey(_ keyString: String) async throws {
        let (normalizedKey, keyData) = try normalizeKeyInput(keyString)
        let previousKey = loadKeyFromKeychain()

        // Create SymmetricKey
        self.encryptionKey = SymmetricKey(data: keyData)

        // Store the key in Keychain with prefix
        try saveKeyToKeychain(normalizedKey)
        try updateKeyHistory(withNewKey: normalizedKey, previousKey: previousKey)
    }
    
    /// Get current encryption key as alphanumeric string
    func getKey() -> String? {
        return loadKeyFromKeychain()
    }
    
    /// Check if an encryption key exists in the keychain
    /// Returns true if key exists OR if we previously set up a key (to handle temporary keychain failures)
    func hasEncryptionKey() -> Bool {
        if loadKeyFromKeychain() != nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: encryptionKeySetupFlagKey)
    }

    /// Check if the encryption key is actually available (not just previously set up)
    func isKeyAvailable() -> Bool {
        return loadKeyFromKeychain() != nil
    }
    
    /// Get history of previously used encryption keys
    func getKeyHistory() -> [String] {
        return loadKeyHistory()
    }

    /// Remove encryption key
    func clearKey() {
        encryptionKey = nil
        deleteKeyFromKeychain()
        deleteKeyHistoryFromKeychain()
        UserDefaults.standard.removeObject(forKey: encryptionKeySetupFlagKey)
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt data
    func encrypt<T: Encodable>(_ data: T) async throws -> EncryptedData {
        // Don't set date encoding - let StoredChat handle its own format
        let jsonData = try JSONEncoder().encode(data)
        return try await encryptData(jsonData)
    }
    
    /// Decrypt data
    func decrypt<T: Decodable>(_ encryptedData: EncryptedData, as type: T.Type) async throws -> DecryptionResult<T> {
        let (data, usedFallback) = try await decryptDataWithFallbackInfo(encryptedData)
        let value = try JSONDecoder().decode(type, from: data)
        return DecryptionResult(value: value, usedFallbackKey: usedFallback)
    }

    // MARK: - V1 Binary Encryption/Decryption

    /// Encrypt data using v1 format: JSON → gzip → AES-GCM → raw binary.
    func encryptV1<T: Encodable>(_ data: T) throws -> Data {
        guard let key = encryptionKey else {
            throw EncryptionError.keyNotInitialized
        }
        return try BinaryCodec.compressAndEncrypt(data, using: key)
    }

    /// Decrypt v1 binary data, trying the primary key then falling back to key history.
    func decryptV1<T: Decodable>(_ binary: Data, as type: T.Type) throws -> DecryptionResult<T> {
        let (value, usedFallback) = try decryptWithKeyFallback { key in
            try BinaryCodec.decryptAndDecompress(binary, using: key, as: type)
        }
        return DecryptionResult(value: value, usedFallbackKey: usedFallback)
    }

    // MARK: - Helper Methods

    /// Try the primary key first, then iterate through key history on failure.
    /// Returns the result and whether a fallback key was used.
    private func decryptWithKeyFallback<T>(
        _ operation: (SymmetricKey) throws -> T
    ) throws -> (T, Bool) {
        guard let defaultKey = encryptionKey else {
            throw EncryptionError.keyNotInitialized
        }

        do {
            return (try operation(defaultKey), false)
        } catch {
            var lastError = error
            for legacyKey in loadKeyHistory() {
                do {
                    let key = try symmetricKey(from: legacyKey)
                    return (try operation(key), true)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private func normalizeKeyInput(_ keyString: String) throws -> (String, Data) {
        guard keyString.hasPrefix("key_") else {
            throw EncryptionError.invalidKeyFormat
        }

        let processedKey = String(keyString.dropFirst(4))
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if processedKey.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
            throw EncryptionError.invalidKeyCharacters
        }

        let keyData = try alphanumericToBytes(processedKey)
        let normalizedKey = "key_" + processedKey
        return (normalizedKey, keyData)
    }

    private func symmetricKey(from keyString: String) throws -> SymmetricKey {
        let (_, keyData) = try normalizeKeyInput(keyString)
        return SymmetricKey(data: keyData)
    }

    private func updateKeyHistory(withNewKey newKey: String, previousKey: String?) throws {
        var history = loadKeyHistory()

        // Remove any existing occurrences of the current default key
        history.removeAll { $0 == newKey }

        if let previousKey = previousKey, previousKey != newKey {
            // Move previous key to the front to preserve recency ordering
            history.removeAll { $0 == previousKey }
            history.insert(previousKey, at: 0)
        }

        try saveKeyHistory(history)
    }

    private func loadKeyHistory() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainHistoryKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let history = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return history
    }

    private func saveKeyHistory(_ history: [String]) throws {
        if history.isEmpty {
            deleteKeyHistoryFromKeychain()
            return
        }

        let data = try JSONEncoder().encode(history)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainHistoryKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete any existing item before saving
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }
    }

    private func deleteKeyHistoryFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainHistoryKey
        ]

        SecItemDelete(query as CFDictionary)
    }

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
    
    func saveKeyToKeychain(_ key: String) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let data = key.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKey
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }

        UserDefaults.standard.set(true, forKey: encryptionKeySetupFlagKey)
    }

    private func loadKeyFromKeychain() -> String? {
        keychainLock.lock()
        defer { keychainLock.unlock() }

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

// MARK: - ChatEncryptor Conformance

extension EncryptionService: ChatEncryptor {
    func encryptData(_ data: Data) async throws -> EncryptedData {
        guard let encryptionKey = encryptionKey else {
            throw EncryptionError.keyNotInitialized
        }

        return try AESGCMHelper.seal(data, using: encryptionKey)
    }

    func decryptData(_ encrypted: EncryptedData) async throws -> Data {
        let (data, _) = try await decryptDataWithFallbackInfo(encrypted)
        return data
    }

    /// Shared decryption that tries the primary key, then falls back to key history.
    /// Returns the decrypted data and whether a fallback key was used.
    private func decryptDataWithFallbackInfo(_ encrypted: EncryptedData) async throws -> (Data, Bool) {
        let sealedBox = try AESGCMHelper.parseSealedBox(from: encrypted)
        return try decryptWithKeyFallback { key in
            try AES.GCM.open(sealedBox, using: key)
        }
    }
}

// MARK: - Encryption Errors

enum EncryptionError: LocalizedError {
    case keyNotInitialized
    case invalidKeyFormat
    case invalidKeyCharacters
    case invalidKeyLength
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
        case .invalidEncryptedData:
            return "Missing IV or data in encrypted data"
        case .invalidBase64:
            return "Invalid base64 encoding"
        case .keychainSaveFailed(let status):
            return "Failed to save encryption key to keychain (error: \(status))"
        }
    }
}
