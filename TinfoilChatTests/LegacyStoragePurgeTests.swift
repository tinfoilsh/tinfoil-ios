import Foundation
import Testing
import TinfoilPasskeyKit
@testable import TinfoilChat

@Suite("Legacy storage purge")
struct LegacyStoragePurgeTests {
    private let prfCache = MemoryKeychain.Item(Constants.Passkey.rpId, Constants.Passkey.prfCacheKeychainAccount)

    @Test func removesThePasskeyPRFOutputOnce() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()
        keychain.items[prfCache] = Data("prf".utf8)

        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain)

        #expect(keychain.items[prfCache] == nil)
        #expect(defaults.bool(forKey: LegacyStoragePurge.completedKey))
    }

    @Test func runsAgainWhileTheKeychainIsLocked() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()
        keychain.items[prfCache] = Data("prf".utf8)
        keychain.failure = .unavailable

        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain)
        #expect(!defaults.bool(forKey: LegacyStoragePurge.completedKey))

        keychain.failure = nil
        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain)
        #expect(keychain.items[prfCache] == nil)
        #expect(defaults.bool(forKey: LegacyStoragePurge.completedKey))
    }

    @MainActor
    @Test func passkeyStorageKeepsOnlyTheCredentialId() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let storage = LocalCredentialPasskeyStorage(defaults: defaults, credentialIdKey: "credential")

        try storage.saveCachedPRFResult(CachedPRFResult(
            profile: TinfoilPasskeyProfile.current,
            credentialId: "AQID",
            prfOutput: Data(repeating: 7, count: 32)
        ))
        try storage.saveLocalCredentialId("AQID")

        #expect(try storage.loadCachedPRFResult() == nil)
        #expect(try storage.loadLocalCredentialId() == "AQID")
    }

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let name = "LegacyStoragePurgeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }
}
