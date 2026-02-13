//
//  DeviceEncryptionService.swift
//  TinfoilChat
//
//  Auto-generated AES-256-GCM device key for encrypting local-only chats.
//  The key never leaves the device and is stored in the keychain with
//  kSecAttrAccessibleWhenUnlockedThisDeviceOnly (no iCloud Keychain sync).
//

import Foundation
import CryptoKit
import Security

actor DeviceEncryptionService: ChatEncryptor {
    static let shared = DeviceEncryptionService()

    private let keychainService = "sh.tinfoil.device"
    private let keychainAccount = "deviceKey"

    private var cachedKey: SymmetricKey?

    private var baseKeychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private init() {}

    // MARK: - ChatEncryptor

    func encryptData(_ data: Data) async throws -> EncryptedData {
        let key = try getOrCreateKey()
        return try AESGCMHelper.seal(data, using: key)
    }

    func decryptData(_ encrypted: EncryptedData) async throws -> Data {
        let key = try getOrCreateKey()
        return try AESGCMHelper.open(encrypted, using: key)
    }

    // MARK: - Key Management

    /// Removes the device key from the keychain (used during destructive cleanup).
    func clearKey() {
        cachedKey = nil
        SecItemDelete(baseKeychainQuery as CFDictionary)
    }

    // MARK: - Private

    private func getOrCreateKey() throws -> SymmetricKey {
        if let key = cachedKey { return key }

        if let existing = loadKeyFromKeychain() {
            cachedKey = existing
            return existing
        }

        let newKey = SymmetricKey(size: .bits256)
        try saveKeyToKeychain(newKey)
        cachedKey = newKey
        return newKey
    }

    private func loadKeyFromKeychain() -> SymmetricKey? {
        var query = baseKeychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    private func saveKeyToKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        let attributes: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(baseKeychainQuery as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = baseKeychainQuery
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }
    }
}
