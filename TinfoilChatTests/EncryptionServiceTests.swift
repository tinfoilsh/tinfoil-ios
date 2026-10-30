import Foundation
import Security
import Testing
@testable import TinfoilChat

/// Each test keeps its keys under a keychain service of its own, removed
/// when it ends.
@Suite("Content key storage")
struct EncryptionServiceTests {
    private let keyAccount = "sh.tinfoil.encryptionKey"
    private let historyAccount = "key_history"

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

    /// Keychain items outlive the app: a key that records no account may be
    /// one a deleted install kept for someone else.
    @Test func keyStoredWithoutAnAccountIsRemoved() throws {
        let (service, name, cleanup) = try makeService()
        defer { cleanup() }
        let key = service.generateKey()
        try storeUnownedKey(key, replacing: [service.generateKey()], keychainService: name)

        service.bind(userId: "user-a")
        #expect(service.getKey() == nil)
        #expect(try service.getAllKeys().alternatives.isEmpty)

        service.claimUnownedKey(for: "user-a")
        service.bind(userId: "user-a")
        #expect(service.getKey() == nil)
    }

    @Test func keyClaimedForAnAccountIsKeptOnlyForIt() throws {
        let (service, name, cleanup) = try makeService()
        defer { cleanup() }
        let key = service.generateKey()
        try storeUnownedKey(key, keychainService: name)

        service.claimUnownedKey(for: "user-a")
        service.claimUnownedKey(for: "user-b")
        service.bind(userId: "user-a")
        #expect(service.getKey() == key)

        service.bind(userId: "user-b")
        #expect(service.getKey() == nil)
    }

    /// A claim the keychain could not take, as while the device is locked,
    /// waits in the defaults for the next bind.
    @Test func waitingClaimIsCompletedBeforeTheKeyIsBound() throws {
        let (service, name, cleanup) = try makeService()
        defer { cleanup() }
        let key = service.generateKey()
        try storeUnownedKey(key, keychainService: name)
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set("user-a", forKey: Constants.StorageKeys.Secret.encryptionKeyClaim)

        service.bind(userId: "user-a")

        #expect(service.getKey() == key)
        #expect(defaults.object(forKey: Constants.StorageKeys.Secret.encryptionKeyClaim) == nil)
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

    /// Stores a key, and the keys it replaced, as installs did before keys
    /// recorded their account.
    private func storeUnownedKey(_ key: String, replacing history: [String] = [], keychainService: String) throws {
        addItem(Data(key.utf8), account: keyAccount, keychainService: keychainService)
        if !history.isEmpty {
            addItem(try JSONEncoder().encode(history), account: historyAccount, keychainService: keychainService)
        }
    }

    private func addItem(_ data: Data, account: String, keychainService: String) {
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)
        #expect(status == errSecSuccess)
    }
}
