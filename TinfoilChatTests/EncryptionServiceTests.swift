import Foundation
import Security
import Testing
@testable import TinfoilChat

/// Each test keeps its keys under a keychain service of its own, removed
/// when it ends.
@Suite("Content key storage")
struct EncryptionServiceTests {
    private let keyAccount = "sh.tinfoil.encryptionKey"

    @Test func keyIsReadOnlyForTheAccountThatStoredIt() async throws {
        let (service, _, cleanup) = try makeService()
        defer { cleanup() }
        let key = service.generateKey()

        service.bind(userId: "user-a")
        try await service.setKey(key)
        service.bind(userId: nil)
        #expect(service.getKey() == nil)

        service.bind(userId: "user-a")
        #expect(service.getKey() == key)
    }

    @Test func keyAnotherAccountStoredIsRemoved() async throws {
        let (service, _, cleanup) = try makeService()
        defer { cleanup() }

        service.bind(userId: "user-a")
        try await service.setKey(service.generateKey())
        service.bind(userId: "user-b")
        #expect(service.getKey() == nil)

        service.bind(userId: "user-a")
        #expect(service.getKey() == nil)
    }

    @Test func keyStoredWithoutAnAccountIsAdoptedOnce() throws {
        let (service, name, cleanup) = try makeService()
        defer { cleanup() }
        let key = service.generateKey()
        try storeUnownedKey(key, keychainService: name)

        service.bind(userId: "user-a")
        #expect(service.getKey() == key)

        service.bind(userId: "user-b")
        #expect(service.getKey() == nil)
        service.bind(userId: "user-a")
        #expect(service.getKey() == nil)
    }

    @Test func replacedKeyIsKeptUnlessStartingFresh() async throws {
        let (service, _, cleanup) = try makeService()
        defer { cleanup() }
        let first = service.generateKey()
        let second = service.generateKey()
        service.bind(userId: "user-a")

        try await service.setKey(first)
        try await service.setKey(second)
        #expect(try service.getAllKeys().alternatives == [first])

        try await service.setKey(service.generateKey(), persist: false)
        try service.persistCurrentKeyState(discardingHistory: true)
        #expect(try service.getAllKeys().alternatives.isEmpty)
    }

    @Test func keyIsNotStoredWithoutAnAccount() async throws {
        let (service, _, cleanup) = try makeService()
        defer { cleanup() }

        await #expect(throws: EncryptionError.self) {
            try await service.setKey(service.generateKey())
        }
    }

    private func makeService() throws -> (EncryptionService, String, () -> Void) {
        let name = "EncryptionServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let service = EncryptionService(keychainService: name, defaults: defaults)
        return (service, name, {
            service.clearKey()
            defaults.removePersistentDomain(forName: name)
        })
    }

    /// Stores a key as installs did before keys recorded their account.
    private func storeUnownedKey(_ key: String, keychainService: String) throws {
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyAccount,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)
        #expect(status == errSecSuccess)
    }
}
