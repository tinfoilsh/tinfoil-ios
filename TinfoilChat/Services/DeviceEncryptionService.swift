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

    func decryptData(_ encrypted: EncryptedData) async throws -> Data {
        let key = try getOrCreateKey()

        guard let ivData = Data(base64Encoded: encrypted.iv),
              let combinedData = Data(base64Encoded: encrypted.data) else {
            throw EncryptionError.invalidBase64
        }

        let tagSize = 16
        guard combinedData.count > tagSize else {
            throw EncryptionError.invalidEncryptedData
        }

        let nonce = try AES.GCM.Nonce(data: ivData)
        let ciphertext = combinedData.prefix(combinedData.count - tagSize)
        let tag = combinedData.suffix(tagSize)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        return try AES.GCM.open(sealedBox, using: key)
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

        var query = baseKeychainQuery
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status: status)
        }
    }
}
