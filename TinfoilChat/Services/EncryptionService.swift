//
//  EncryptionService.swift
//  TinfoilChat
//
//  Encryption service for end-to-end encryption of chat data
//

import Foundation
import CryptoKit
import OSLog
import Security

/// Represents encrypted data with initialization vector
struct EncryptedData: Codable {
    let iv: String  // Base64 encoded initialization vector
    let data: String  // Base64 encoded encrypted data
}

/// Keeps the account's content key, and the keys it replaced, in the
/// Keychain. The key is stored with the account it belongs to, and is used
/// only while that account is the one bound.
class EncryptionService: ObservableObject, @unchecked Sendable {
    static let shared = EncryptionService()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Keys")
    static let defaultKeychainService = "sh.tinfoil.chat"

    private let keychainKey = "sh.tinfoil.encryptionKey"
    private let keychainService: String
    private let keychainHistoryKey = "key_history"
    private let encryptionKeySetupFlagKey = Constants.StorageKeys.Secret.encryptionKeySetUp
    private let defaults: UserDefaults
    private let keychainLock = NSLock()

    /// The signed-in account, whose key alone is read and stored.
    private var _owner: String?

    private var owner: String? {
        get { keychainLock.withLock { _owner } }
        set { keychainLock.withLock { _owner = newValue } }
    }

    /// Primary key staged in memory but not yet written to the Keychain.
    /// Set by `setKey(_:persist:)` with `persist: false` so the registry
    /// checks the new key while the Keychain still holds the previous one.
    /// Committed by `persistCurrentKeyState()` only after the registry
    /// accepts it, or dropped by `discardStagedKeyState()` on failure.
    private var _stagedPrimaryKey: String?

    private var stagedPrimaryKey: String? {
        get { keychainLock.withLock { _stagedPrimaryKey } }
        set { keychainLock.withLock { _stagedPrimaryKey = newValue } }
    }

    init(keychainService: String = EncryptionService.defaultKeychainService, defaults: UserDefaults = .standard) {
        self.keychainService = keychainService
        self.defaults = defaults
    }

    // MARK: - Account

    /// Binds the key to the signed-in account, or to none when signed out.
    /// A key stored for another account, or for none, is removed: keychain
    /// items outlive the app, so a key that records no account may be one
    /// a deleted install kept for someone else. The key an older version
    /// kept on this install records its account through
    /// `claimUnownedKey(for:)` first.
    func bind(userId: String?) {
        stagedPrimaryKey = nil
        owner = userId
        guard let userId else { return }
        let stored: StoredKey?
        do {
            stored = try loadStoredKey()
        } catch {
            Self.logger.error("Failed to read the encryption key's account: \(error, privacy: .public)")
            return
        }
        guard let stored, stored.owner != userId else { return }
        clearKey()
    }

    /// Records the account of a key stored before keys recorded their
    /// account. Only this install's own record of who was signed in under
    /// the older version may name it.
    func claimUnownedKey(for userId: String) {
        let stored: StoredKey?
        do {
            stored = try loadStoredKey()
        } catch {
            Self.logger.error("Failed to read the encryption key's account: \(error, privacy: .public)")
            return
        }
        guard let stored, stored.owner == nil else { return }
        let status = SecItemUpdate(
            itemQuery(account: keychainKey) as CFDictionary,
            [kSecAttrGeneric as String: Data(userId.utf8)] as CFDictionary
        )
        if status != errSecSuccess {
            Self.logger.error("Failed to record the encryption key's account: \(status, privacy: .public)")
        }
    }

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
        guard let storedKey = try loadKeyFromKeychain() else {
            throw EncryptionError.keyNotInitialized
        }

        try await setKey(storedKey)
        return storedKey
    }

    /// Set encryption key from alphanumeric string.
    ///
    /// When `persist` is false the key is staged in memory (so the
    /// registry requests and `getKey()` use it) but not written to the
    /// Keychain. Callers must follow up with `persistCurrentKeyState()`
    /// once the registry accepts the key, or `discardStagedKeyState()` to
    /// roll back.
    ///
    /// The replaced key joins the history, unless `discardingHistory`,
    /// which drops it and every older one, as a start-fresh does once the
    /// registry deleted the rows they sealed.
    func setKey(_ keyString: String, persist: Bool = true, discardingHistory: Bool = false) async throws {
        let (normalizedKey, _) = try normalizeKeyInput(keyString)

        guard persist else {
            stagedPrimaryKey = normalizedKey
            return
        }

        try store(normalizedKey, discardingHistory: discardingHistory)
        stagedPrimaryKey = nil
    }
    
    /// Get current encryption key as alphanumeric string, or nil when none
    /// is set or the Keychain cannot be read.
    func getKey() -> String? {
        return stagedPrimaryKey ?? (try? loadKeyFromKeychain())
    }

    /// Check if an encryption key exists in the keychain
    /// Returns true if key exists OR if we previously set up a key (to handle temporary keychain failures)
    func hasEncryptionKey() -> Bool {
        if (try? loadKeyFromKeychain()) != nil {
            return true
        }
        return defaults.bool(forKey: encryptionKeySetupFlagKey)
    }

    /// Get the primary key and all alternative (fallback) keys as a bundle.
    /// Used by passkey backup to snapshot the full key state for encryption.
    func getAllKeys() throws -> (primary: String?, alternatives: [String]) {
        return (primary: try loadKeyFromKeychain(), alternatives: try loadKeyHistory())
    }

    /// Return the raw 32-byte CEK for the primary key. Throws when no
    /// primary key is loaded. The chat service expects the raw CEK,
    /// base64-encoded, with every request about stored chats.
    func getKeyBytesOrThrow() throws -> Data {
        guard let key = try stagedPrimaryKey ?? loadKeyFromKeychain() else {
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

    /// Set the primary key from a CEK provided as raw 32 bytes, e.g. one
    /// freshly generated or recovered from a passkey bundle. Encodes the
    /// bytes back into the alphanumeric keychain format so the rest of the
    /// app keeps working unchanged.
    func setKeyBytes(_ bytes: Data, discardingHistory: Bool = false) async throws {
        try await setKey(encodeKeyFromBytes(bytes), discardingHistory: discardingHistory)
    }

    /// Encode raw CEK bytes into the canonical `key_<base36>` string
    /// the rest of the app stores and compares. Mirrors the webapp's
    /// `encodeKeyFromBytes`.
    func encodeKeyFromBytes(_ bytes: Data) -> String {
        return "key_" + bytesToAlphanumeric(bytes)
    }

    /// Add a decryption-only fallback key without changing the primary key.
    func addDecryptionKey(_ keyString: String) throws {
        let (normalizedKey, _) = try normalizeKeyInput(keyString)

        if normalizedKey == (try loadKeyFromKeychain()) {
            return
        }

        var history = try loadKeyHistory()
        guard !history.contains(normalizedKey) else { return }

        history.append(normalizedKey)
        try saveKeyHistory(history)
    }

    /// Replace the full key bundle exactly, preserving only the provided primary and fallback keys.
    func replaceKeyBundle(primary: String?, alternatives: [String]) throws {
        if let primary {
            let (normalizedPrimary, _) = try normalizeKeyInput(primary)
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

    /// Commit a key staged via `setKey(_:persist:false)` to the Keychain.
    /// No-op when nothing is staged. Call this only after the registry has
    /// accepted the key. `discardingHistory` is as for `setKey`.
    func persistCurrentKeyState(discardingHistory: Bool = false) throws {
        guard let staged = stagedPrimaryKey else { return }

        try store(staged, discardingHistory: discardingHistory)

        stagedPrimaryKey = nil
    }

    /// Drop the keys the primary replaced, once no row sealed under one
    /// remains.
    func clearKeyHistory() throws {
        try saveKeyHistory([])
    }

    /// Drop a staged key without persisting it, so the persisted Keychain
    /// key is the active one again.
    func discardStagedKeyState() {
        stagedPrimaryKey = nil
    }

    /// Remove the encryption key and the keys it replaced. Returns whether
    /// both are gone; a failure is logged.
    @discardableResult
    func clearKey() -> Bool {
        stagedPrimaryKey = nil
        let keyStatus = deleteKeyFromKeychain()
        let historyStatus = deleteKeyHistoryFromKeychain()
        defaults.removeObject(forKey: encryptionKeySetupFlagKey)
        let failures = [keyStatus, historyStatus].filter { $0 != errSecSuccess && $0 != errSecItemNotFound }
        for status in failures {
            Self.logger.error("Failed to remove the encryption key from the keychain: \(status, privacy: .public)")
        }
        return failures.isEmpty
    }
    
    // MARK: - Helper Methods

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
        guard keyData.count == ContentKeyBundle.cekByteCount else {
            throw EncryptionError.invalidKeyLength
        }
        let normalizedKey = "key_" + processedKey
        return (normalizedKey, keyData)
    }

    private func store(_ key: String, discardingHistory: Bool) throws {
        let previousKey = try loadKeyFromKeychain()
        try saveKeyToKeychain(key)
        if discardingHistory {
            try saveKeyHistory([])
        } else {
            try updateKeyHistory(withNewKey: key, previousKey: previousKey)
        }
    }

    private func updateKeyHistory(withNewKey newKey: String, previousKey: String?) throws {
        var history = try loadKeyHistory()

        // Remove any existing occurrences of the current default key
        history.removeAll { $0 == newKey }

        if let previousKey = previousKey, previousKey != newKey {
            // Move previous key to the front to preserve recency ordering
            history.removeAll { $0 == previousKey }
            history.insert(previousKey, at: 0)
        }

        try saveKeyHistory(history)
    }

    /// The replaced keys, newest first; none when no history is stored.
    /// Throws when the Keychain cannot be read, as while the device is
    /// locked.
    private func loadKeyHistory() throws -> [String] {
        var query = itemQuery(account: keychainHistoryKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        guard let history = try? JSONDecoder().decode([String].self, from: data) else {
            Self.logger.error("The stored key history could not be read")
            return []
        }
        return history
    }

    /// Stores the history in place, so a failed save leaves the previous
    /// one; an empty history removes it.
    private func saveKeyHistory(_ history: [String]) throws {
        if history.isEmpty {
            let status = deleteKeyHistoryFromKeychain()
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EncryptionError.keychainSaveFailed(status: status)
            }
            return
        }

        let data = try JSONEncoder().encode(history)
        let query = itemQuery(account: keychainHistoryKey)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }
    }

    private func deleteKeyHistoryFromKeychain() -> OSStatus {
        SecItemDelete(itemQuery(account: keychainHistoryKey) as CFDictionary)
    }

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
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
    
    /// Stores the primary key for the bound account.
    func saveKeyToKeychain(_ key: String) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        guard let owner = _owner else { throw EncryptionError.noAccount }
        let query = itemQuery(account: keychainKey)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrGeneric as String: Data(owner.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }

        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }

        defaults.set(true, forKey: encryptionKeySetupFlagKey)
    }

    /// The bound account's primary key, or nil when none is stored or the
    /// stored one is another account's. Throws when the Keychain cannot be
    /// read, as while the device is locked.
    private func loadKeyFromKeychain() throws -> String? {
        guard let stored = try loadStoredKey() else { return nil }
        let owner = keychainLock.withLock { _owner }
        guard let owner, stored.owner == owner else { return nil }
        return stored.key
    }

    /// A stored primary key and the account it records, if any.
    private struct StoredKey {
        let key: String
        let owner: String?
    }

    private func loadStoredKey() throws -> StoredKey? {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        var query = itemQuery(account: keychainKey)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else {
            throw KeychainError(status: status)
        }
        guard let key = String(data: data, encoding: .utf8) else { return nil }
        let owner = (item[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return StoredKey(key: key, owner: owner)
    }
    
    private func deleteKeyFromKeychain() -> OSStatus {
        SecItemDelete(itemQuery(account: keychainKey) as CFDictionary)
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
    case noAccount

    var errorDescription: String? {
        switch self {
        case .keyNotInitialized:
            return "Encryption key not initialized"
        case .invalidKeyFormat:
            return "Key must start with 'key_' prefix"
        case .invalidKeyCharacters:
            return "Key must only contain lowercase letters and numbers after the prefix"
        case .invalidKeyLength:
            return "Key must decode to exactly \(ContentKeyBundle.cekByteCount) bytes"
        case .invalidEncryptedData:
            return "Missing IV or data in encrypted data"
        case .invalidBase64:
            return "Invalid base64 encoding"
        case .keychainSaveFailed(let status):
            return "Failed to save encryption key to keychain (error: \(status))"
        case .noAccount:
            return "Sign in to keep an encryption key on this device."
        }
    }
}
