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
class EncryptionService: ObservableObject, @unchecked Sendable {
    static let shared = EncryptionService()

    private let keychainKey = "sh.tinfoil.encryptionKey"
    private let keychainService = "sh.tinfoil.chat"
    private let keychainHistoryKey = "key_history"
    private let encryptionKeySetupFlagKey = Constants.StorageKeys.Secret.encryptionKeySetUp
    private var _encryptionKey: SymmetricKey?
    private let keychainLock = NSLock()

    /// Primary key staged in memory but not yet written to the Keychain.
    /// Set by `setKey(_:persist:)` with `persist: false` so the enclave
    /// handshake runs against the new key while the Keychain still holds
    /// the previous one. Committed by `persistCurrentKeyState()` only
    /// after the enclave accepts it, or dropped by
    /// `discardStagedKeyState()` on failure.
    private var _stagedPrimaryKey: String?
    private var _stagedAlternatives: [String]?

    /// Thread-safe access to the in-memory encryption key.
    private var encryptionKey: SymmetricKey? {
        get { keychainLock.withLock { _encryptionKey } }
        set { keychainLock.withLock { _encryptionKey = newValue } }
    }

    private var stagedPrimaryKey: String? {
        get { keychainLock.withLock { _stagedPrimaryKey } }
        set { keychainLock.withLock { _stagedPrimaryKey = newValue } }
    }

    private var stagedAlternatives: [String]? {
        get { keychainLock.withLock { _stagedAlternatives } }
        set { keychainLock.withLock { _stagedAlternatives = newValue } }
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

    /// Set encryption key from alphanumeric string.
    ///
    /// When `persist` is false the key is loaded into memory and staged
    /// (so the enclave wire and `getKey()` use it) but not written to the
    /// Keychain. Callers must follow up with `persistCurrentKeyState()`
    /// once the enclave accepts the key, or `discardStagedKeyState()` to
    /// roll back.
    func setKey(_ keyString: String, persist: Bool = true) async throws {
        let (normalizedKey, keyData) = try normalizeKeyInput(keyString)

        // The in-memory key always reflects the active (possibly staged)
        // key so local encrypt/decrypt works immediately.
        self.encryptionKey = SymmetricKey(data: keyData)

        guard persist else {
            stagedPrimaryKey = normalizedKey
            stagedAlternatives = nil
            return
        }

        let previousKey = loadKeyFromKeychain()
        try saveKeyToKeychain(normalizedKey)
        try updateKeyHistory(withNewKey: normalizedKey, previousKey: previousKey)
        stagedPrimaryKey = nil
        stagedAlternatives = nil
    }
    
    /// Get current encryption key as alphanumeric string
    func getKey() -> String? {
        return stagedPrimaryKey ?? loadKeyFromKeychain()
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

    /// Get the primary key and all alternative (fallback) keys as a bundle.
    /// Used by passkey backup to snapshot the full key state for encryption.
    func getAllKeys() -> (primary: String?, alternatives: [String]) {
        return (primary: loadKeyFromKeychain(), alternatives: loadKeyHistory())
    }

    /// Return the raw 32-byte CEK for the primary key. Throws when no
    /// primary key is loaded. Used by the sync-enclave wire which
    /// expects a base64-encoded raw CEK on every push / pull / delete.
    func getKeyBytesOrThrow() throws -> Data {
        guard let key = stagedPrimaryKey ?? loadKeyFromKeychain() else {
            throw EncryptionError.keyNotInitialized
        }
        let (_, bytes) = try normalizeKeyInput(key)
        return bytes
    }

    /// Decode an arbitrary `key_xxx` alphanumeric string to its raw
    /// bytes. Used by the migration-sweep path which iterates over the
    /// primary + every alternative key.
    func getAlternativeKeyBytes(_ key: String) throws -> Data {
        let (_, bytes) = try normalizeKeyInput(key)
        return bytes
    }

    /// Set the primary key from a fresh CEK provided as raw 32 bytes,
    /// e.g. one minted server-side by the enclave or recovered from a
    /// passkey bundle. Encodes the bytes back into the alphanumeric
    /// keychain format so the rest of the app keeps working unchanged.
    func setKeyBytes(_ bytes: Data) async throws {
        try await setKey(encodeKeyFromBytes(bytes))
    }

    /// Encode raw CEK bytes into the canonical `key_<base36>` string
    /// the rest of the app stores and compares. Mirrors the webapp's
    /// `encodeKeyFromBytes`.
    func encodeKeyFromBytes(_ bytes: Data) -> String {
        return "key_" + bytesToAlphanumeric(bytes)
    }

    /// Number of historical "alternative" decryption keys currently
    /// stored. Used by the enclave-driven legacy migration to report
    /// progress and to confirm cleanup is needed.
    func getFallbackKeyCount() -> Int {
        return loadKeyHistory().count
    }

    /// Drop every historical decryption key, leaving only the primary
    /// in place. Called once `migrate-all` confirms every legacy row
    /// has been re-sealed under the primary CEK.
    func clearFallbackKeys() {
        try? saveKeyHistory([])
    }

    /// Add a decryption-only fallback key without changing the primary key.
    func addDecryptionKey(_ keyString: String) throws {
        let (normalizedKey, _) = try normalizeKeyInput(keyString)

        if normalizedKey == loadKeyFromKeychain() {
            return
        }

        var history = loadKeyHistory()
        guard !history.contains(normalizedKey) else { return }

        history.append(normalizedKey)
        try saveKeyHistory(history)
    }

    /// Bulk-load primary + alternative keys from an external source (e.g. passkey recovery).
    /// Sets the primary key and merges validated alternatives into key history.
    func setAllKeys(primary: String, alternatives: [String], persist: Bool = true) async throws {
        try await setKey(primary, persist: persist)

        guard persist else {
            stagedAlternatives = alternatives
            return
        }

        var existingHistory = loadKeyHistory()
        var addedNew = false

        for key in alternatives {
            if key == primary { continue }
            do {
                _ = try normalizeKeyInput(key)
            } catch {
                continue
            }
            if !existingHistory.contains(key) {
                existingHistory.append(key)
                addedNew = true
            }
        }

        if addedNew {
            try saveKeyHistory(existingHistory)
        }
    }

    /// Replace the full key bundle exactly, preserving only the provided primary and fallback keys.
    func replaceKeyBundle(primary: String?, alternatives: [String]) throws {
        if let primary {
            let (normalizedPrimary, keyData) = try normalizeKeyInput(primary)
            encryptionKey = SymmetricKey(data: keyData)
            try saveKeyToKeychain(normalizedPrimary)

            let normalizedAlternatives = alternatives.compactMap { key -> String? in
                guard key != normalizedPrimary else { return nil }
                return try? normalizeKeyInput(key).0
            }

            var seenAlternatives = Set<String>()
            let deduplicatedAlternatives = normalizedAlternatives.filter {
                seenAlternatives.insert($0).inserted
            }
            try saveKeyHistory(deduplicatedAlternatives)
            return
        }

        clearKey()
    }

    /// Commit a key staged via `setKey(_:persist:false)` or
    /// `setAllKeys(...:persist:false)` to the Keychain. No-op when nothing
    /// is staged. Call this only after the enclave has accepted the key.
    func persistCurrentKeyState() throws {
        guard let staged = stagedPrimaryKey else { return }

        let previousKey = loadKeyFromKeychain()
        try saveKeyToKeychain(staged)
        try updateKeyHistory(withNewKey: staged, previousKey: previousKey)

        if let alternatives = stagedAlternatives {
            var existingHistory = loadKeyHistory()
            var addedNew = false
            for key in alternatives {
                if key == staged { continue }
                guard (try? normalizeKeyInput(key)) != nil else { continue }
                if !existingHistory.contains(key) {
                    existingHistory.append(key)
                    addedNew = true
                }
            }
            if addedNew {
                try saveKeyHistory(existingHistory)
            }
        }

        stagedPrimaryKey = nil
        stagedAlternatives = nil
    }

    /// Drop a staged key without persisting it and restore the in-memory
    /// key to the persisted Keychain value so local encrypt/decrypt keeps
    /// using the real active key.
    func discardStagedKeyState() {
        guard stagedPrimaryKey != nil || stagedAlternatives != nil else { return }
        stagedPrimaryKey = nil
        stagedAlternatives = nil

        if let persisted = loadKeyFromKeychain(),
           let (_, keyData) = try? normalizeKeyInput(persisted) {
            encryptionKey = SymmetricKey(data: keyData)
        } else {
            encryptionKey = nil
        }
    }

    /// Remove encryption key
    func clearKey() {
        encryptionKey = nil
        stagedPrimaryKey = nil
        stagedAlternatives = nil
        deleteKeyFromKeychain()
        deleteKeyHistoryFromKeychain()
        UserDefaults.standard.removeObject(forKey: encryptionKeySetupFlagKey)
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
        guard keyData.count == SyncEnclaveKeyBundle.cekByteCount else {
            throw EncryptionError.invalidKeyLength
        }
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
        let sealedBox = try AESGCMHelper.parseSealedBox(from: encrypted)
        let (data, _) = try decryptWithKeyFallback { key in
            try AES.GCM.open(sealedBox, using: key)
        }
        return data
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
