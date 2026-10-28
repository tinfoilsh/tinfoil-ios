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

        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain, applicationSupport: nil)

        #expect(keychain.items[prfCache] == nil)
        #expect(defaults.bool(forKey: LegacyStoragePurge.completedKey))
    }

    @Test func runsAgainWhileTheKeychainIsLocked() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()
        keychain.items[prfCache] = Data("prf".utf8)
        keychain.failure = .unavailable

        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain, applicationSupport: nil)
        #expect(!defaults.bool(forKey: LegacyStoragePurge.completedKey))

        keychain.failure = nil
        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain, applicationSupport: nil)
        #expect(keychain.items[prfCache] == nil)
        #expect(defaults.bool(forKey: LegacyStoragePurge.completedKey))
    }

    @Test func removesWhatOlderClientsKept() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let support = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let projects = support.appendingPathComponent("tinfoil/projects/user-a", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let keychain = MemoryKeychain()
        let profileService = Constants.Harness.Profile.keychainService
        for key in ["userProfileSyncBaseline", "profileUnknownFields", Constants.Harness.Profile.previousProfileKey, Constants.Harness.Profile.localProfileKey] {
            keychain.items[MemoryKeychain.Item(profileService, key)] = Data("{}".utf8)
        }
        keychain.items[MemoryKeychain.Item(nil, "chat-recovery-user-cache-secret-user-a")] = Data("secret".utf8)
        keychain.items[MemoryKeychain.Item(nil, "clerk-session")] = Data("session".utf8)
        let removedKeys = [
            "tinfoil-sync-device-id", "tinfoil-sync-edit-clock",
            "com.tinfoil.chat.profile.dirty", "com.tinfoil.chat.profile.changed-at",
            "tinfoil-user-prefs-nickname", "tinfoil-user-prefs-profession",
            "tinfoil-user-prefs-traits", "tinfoil-user-prefs-additional-context",
            "tinfoil-sync-revision-checkpoint-v2-user-a", "tinfoil-sync-pagination-token-user-a",
            "tinfoil-sync-pagination-attempted-user-a", "tinfoil-migration-legacy-cloud-chats-evicted_user-a",
            "tinfoil-secret-cloud-key-authorization-user-a",
        ]
        for key in removedKeys { defaults.set("value", forKey: key) }
        defaults.set("gpt-oss-120b", forKey: Constants.StorageKeys.Settings.selectedModel)

        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain, applicationSupport: support)

        #expect(removedKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(defaults.string(forKey: Constants.StorageKeys.Settings.selectedModel) == "gpt-oss-120b")
        #expect(Set(keychain.items.keys) == [
            MemoryKeychain.Item(profileService, Constants.Harness.Profile.localProfileKey),
            MemoryKeychain.Item(nil, "clerk-session"),
        ])
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("tinfoil/projects").path))
        #expect(defaults.bool(forKey: LegacyStoragePurge.completedKey))
    }

    @Test func keepsThePreviousProfileUntilItIsImported() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()
        let previous = MemoryKeychain.Item(Constants.Harness.Profile.keychainService, Constants.Harness.Profile.previousProfileKey)
        keychain.items[previous] = Data("{\"nickname\":\"Al\"}".utf8)

        LegacyStoragePurge.purgeIfNeeded(defaults: defaults, keychain: keychain, applicationSupport: nil)
        #expect(keychain.items[previous] != nil)

        let profile = try DeviceProfileStorage(keychain: keychain, defaults: defaults).loadLocalProfile()
        #expect(profile["nickname"] as? String == "Al")
        #expect(keychain.items[previous] == nil)
    }

    @Test func removesAnAccountsOldDataAsItSignsOut() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()
        keychain.items[MemoryKeychain.Item(nil, "chat-recovery-user-cache-secret-user-a")] = Data("a".utf8)
        keychain.items[MemoryKeychain.Item(nil, "chat-recovery-user-cache-secret-user-b")] = Data("b".utf8)
        defaults.set("a", forKey: "tinfoil-sync-pagination-token-user-a")
        defaults.set("b", forKey: "tinfoil-sync-pagination-token-user-b")

        LegacyStoragePurge.purge(userId: "user-a", defaults: defaults, keychain: keychain)

        #expect(defaults.object(forKey: "tinfoil-sync-pagination-token-user-a") == nil)
        #expect(defaults.string(forKey: "tinfoil-sync-pagination-token-user-b") == "b")
        #expect(Set(keychain.items.keys) == [MemoryKeychain.Item(nil, "chat-recovery-user-cache-secret-user-b")])
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

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyStoragePurgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let name = "LegacyStoragePurgeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }
}
