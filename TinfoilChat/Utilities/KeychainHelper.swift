//
//  KeychainHelper.swift
//  TinfoilChat
//
//  Created on 20/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import Foundation
import Security

/// A helper class for secure storage in the iOS Keychain
class KeychainHelper {
    
    static let shared = KeychainHelper()
    
    private init() {}
    
    /// Save data to the keychain
    /// - Parameters:
    ///   - data: The data to save
    ///   - key: The key to identify this item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: True if saved successfully, false otherwise
    @discardableResult
    func save(_ data: Data, for key: String, service: String? = nil) -> Bool {
        let service = service ?? Bundle.main.bundleIdentifier ?? "com.tinfoil.chat"
        
        // Create query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Save a string to the keychain
    /// - Parameters:
    ///   - string: The string to save
    ///   - key: The key to identify this item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: True if saved successfully, false otherwise
    @discardableResult
    func save(_ string: String, for key: String, service: String? = nil) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(data, for: key, service: service)
    }
    
    /// Retrieve data from the keychain
    /// - Parameters:
    ///   - key: The key to identify the item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: The stored data, or nil if not found
    func load(for key: String, service: String? = nil) -> Data? {
        let service = service ?? Bundle.main.bundleIdentifier ?? "com.tinfoil.chat"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
    
    /// Retrieve a string from the keychain
    /// - Parameters:
    ///   - key: The key to identify the item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: The stored string, or nil if not found
    func loadString(for key: String, service: String? = nil) -> String? {
        guard let data = load(for: key, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Delete an item from the keychain
    /// - Parameters:
    ///   - key: The key to identify the item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: True if deleted successfully, false otherwise
    @discardableResult
    func delete(for key: String, service: String? = nil) -> Bool {
        let service = service ?? Bundle.main.bundleIdentifier ?? "com.tinfoil.chat"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Clear all items for a specific service
    /// - Parameter service: The service name, defaults to bundle identifier
    /// - Returns: True if cleared successfully, false otherwise
    @discardableResult
    func clearAll(for service: String? = nil) -> Bool {
        let service = service ?? Bundle.main.bundleIdentifier ?? "com.tinfoil.chat"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}