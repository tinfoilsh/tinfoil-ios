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
    private let accessGroup: String? = nil
    
    private init() {}
    
    /// Save chats to Keychain
    func saveChats(_ chats: [Chat], userId: String) throws {
        let key = "chats_\(userId)"
        
        // Encode chats to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(chats)
        
        // Delete any existing item
        deleteItem(key: key)
        
        // Create query for adding new item
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        // Add to Keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw KeychainError.saveFailed(status: status)
        }
    }
    
    /// Load chats from Keychain
    func loadChats(userId: String) -> [Chat]? {
        let key = "chats_\(userId)"
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
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