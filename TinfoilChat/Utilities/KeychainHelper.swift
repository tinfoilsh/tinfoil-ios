//
//  KeychainHelper.swift
//  TinfoilChat
//
//  Created on 20/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import Foundation
import Security

/// A keychain request that did not complete. While the device is locked an
/// item is unavailable: it may exist, and can be read once the device is
/// unlocked, so it must not be taken for a missing one.
enum KeychainError: LocalizedError, Equatable {
    case unavailable
    case failed(OSStatus)

    init(status: OSStatus) {
        self = status == errSecInteractionNotAllowed ? .unavailable : .failed(status)
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Unlock your device to continue."
        case .failed(let status):
            return "The keychain could not complete the request (error: \(status))."
        }
    }
}

/// Items kept in the keychain by service and key.
protocol KeychainStore: AnyObject, Sendable {
    func save(_ data: Data, for key: String, service: String?) throws
    func load(for key: String, service: String?) throws -> Data?
    @discardableResult
    func delete(for key: String, service: String?) -> Bool
}

/// A helper class for secure storage in the iOS Keychain
class KeychainHelper: KeychainStore, @unchecked Sendable {
    
    static let shared = KeychainHelper()
    
    private init() {}
    
    /// Save data to the keychain, updating the item in place or adding it
    /// when none exists, so a failed save leaves what was stored.
    /// - Parameters:
    ///   - data: The data to save
    ///   - key: The key to identify this item
    ///   - service: Optional service name, defaults to bundle identifier
    func save(_ data: Data, for key: String, service: String? = nil) throws {
        let query = baseQuery(for: key, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    
    /// Save a string to the keychain
    /// - Parameters:
    ///   - string: The string to save
    ///   - key: The key to identify this item
    ///   - service: Optional service name, defaults to bundle identifier
    func save(_ string: String, for key: String, service: String? = nil) throws {
        try save(Data(string.utf8), for: key, service: service)
    }
    
    /// Retrieve data from the keychain
    /// - Parameters:
    ///   - key: The key to identify the item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: The stored data, or nil if no item exists
    /// - Throws: `KeychainError` when the item cannot be read, as while
    ///   the device is locked
    func load(for key: String, service: String? = nil) throws -> Data? {
        var query = baseQuery(for: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }
    
    /// Retrieve a string from the keychain
    /// - Parameters:
    ///   - key: The key to identify the item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: The stored string, or nil if no item exists or it is not UTF-8
    func loadString(for key: String, service: String? = nil) throws -> String? {
        guard let data = try load(for: key, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Delete an item from the keychain
    /// - Parameters:
    ///   - key: The key to identify the item
    ///   - service: Optional service name, defaults to bundle identifier
    /// - Returns: True if deleted successfully, false otherwise
    @discardableResult
    func delete(for key: String, service: String? = nil) -> Bool {
        let status = SecItemDelete(baseQuery(for: key, service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(for key: String, service: String?) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? Bundle.main.bundleIdentifier ?? "com.tinfoil.chat",
            kSecAttrAccount as String: key
        ]
    }
}
