import Foundation
import Security
import Testing
@testable import TinfoilChat

@Suite("Keychain storage")
struct KeychainStorageTests {
    @Test func lockedKeychainReadsAsUnavailable() {
        #expect(KeychainError(status: errSecInteractionNotAllowed) == .unavailable)
        #expect(KeychainError(status: errSecAuthFailed) == .failed(errSecAuthFailed))
    }

    @Test func saveReplacesTheStoredItem() throws {
        let service = "sh.tinfoil.tests.\(UUID().uuidString)"
        defer { KeychainHelper.shared.delete(for: "item", service: service) }

        #expect(try KeychainHelper.shared.load(for: "item", service: service) == nil)
        try KeychainHelper.shared.save(Data("first".utf8), for: "item", service: service)
        try KeychainHelper.shared.save(Data("second".utf8), for: "item", service: service)

        #expect(try KeychainHelper.shared.load(for: "item", service: service) == Data("second".utf8))
    }

    @Test func unreadableProfileFailsInsteadOfImportingAgain() throws {
        let keychain = MemoryKeychain()
        keychain.failure = .unavailable
        let (defaults, suiteName) = try previousClientDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = DeviceProfileStorage(keychain: keychain, defaults: defaults)

        #expect(throws: KeychainError.unavailable) { try storage.loadLocalProfile() }
        #expect(keychain.saves == 0)
    }

    @Test func missingProfileImportsThePreviousClientsSettings() throws {
        let keychain = MemoryKeychain()
        let (defaults, suiteName) = try previousClientDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = DeviceProfileStorage(keychain: keychain, defaults: defaults)

        let profile = try storage.loadLocalProfile()

        #expect(profile["selectedModel"] as? String == "gpt-oss-120b")
        #expect(keychain.items[MemoryKeychain.Item(Constants.Harness.Profile.keychainService, Constants.Harness.Profile.localProfileKey)] != nil)
    }

    private func previousClientDefaults() throws -> (UserDefaults, String) {
        let suiteName = "KeychainStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set("gpt-oss-120b", forKey: Constants.StorageKeys.Settings.selectedModel)
        return (defaults, suiteName)
    }
}

/// Keychain items in memory, by service and key, which fails every request
/// with `failure` when one is set.
final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    struct Item: Hashable {
        let service: String?
        let key: String

        init(_ service: String?, _ key: String) {
            self.service = service
            self.key = key
        }
    }

    var items: [Item: Data] = [:]
    var failure: KeychainError?
    private(set) var saves = 0

    func save(_ data: Data, for key: String, service: String?) throws {
        if let failure { throw failure }
        saves += 1
        items[Item(service, key)] = data
    }

    func load(for key: String, service: String?) throws -> Data? {
        if let failure { throw failure }
        return items[Item(service, key)]
    }

    func delete(for key: String, service: String?) -> Bool {
        guard failure == nil else { return false }
        items[Item(service, key)] = nil
        return true
    }
}
