//
//  KeychainChatStorage.swift
//  TinfoilChat
//
//  Secure storage for chat data using iOS Keychain
//

import Foundation
import Security

/// Service for securely storing chat data in the iOS Keychain
class KeychainChatStorage {
    static let shared = KeychainChatStorage()

    private let serviceName = "sh.tinfoil.chats"

    private init() {}
    
    /// Save chats to Keychain
    func saveChats(_ chats: [Chat], userId: String) throws {
        let key = "chats_\(userId)"
        
        // Encode chats to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(chats)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        // Attributes for update (only data, not accessibility)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        
        // Try to update existing item first
        var status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        
        // If item doesn't exist, add it with accessibility settings
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        
        if status != errSecSuccess {
            throw KeychainError.saveFailed(status: status)
        }
    }
    
    /// Load chats from Keychain
    func loadChats(userId: String) -> [Chat]? {
        let key = "chats_\(userId)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        
        // Decode chats
        let decoder = JSONDecoder()
        return try? decoder.decode([Chat].self, from: data)
    }
    
    /// Delete chats from Keychain
    func deleteChats(userId: String) {
        let key = "chats_\(userId)"
        deleteItem(key: key)
    }
    
    /// Delete all chats from Keychain
    func deleteAllChats() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    private func deleteItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}

/// Keychain storage errors
enum KeychainError: LocalizedError {
    case saveFailed(status: OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to Keychain: \(status)"
        }
    }
}