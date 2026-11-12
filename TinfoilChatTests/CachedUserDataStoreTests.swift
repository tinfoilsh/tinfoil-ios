import Foundation
import Testing
@testable import TinfoilChat

@Suite("Cached user details")
struct CachedUserDataStoreTests {
    private let item = MemoryKeychain.Item(nil, Constants.StorageKeys.Auth.userData)
    private let details = Data(#"{"id":"user-a","email":"a@example.com"}"#.utf8)

    @Test func movesTheDetailsOlderVersionsKeptIntoTheKeychain() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(details, forKey: Constants.StorageKeys.Auth.userData)
        defaults.set(true, forKey: Constants.StorageKeys.Auth.subscription)
        let keychain = MemoryKeychain()
        let store = CachedUserDataStore(keychain: keychain, defaults: defaults)

        let moved = store.load()
        #expect(moved?.data == details)
        #expect(moved?.isFromOlderVersion == true)

        #expect(keychain.items[item] == details)
        #expect(defaults.object(forKey: Constants.StorageKeys.Auth.userData) == nil)
        #expect(defaults.object(forKey: Constants.StorageKeys.Auth.subscription) == nil)
        let kept = store.load()
        #expect(kept?.data == details)
        #expect(kept?.isFromOlderVersion == false)
    }

    @Test func keepsTheOlderCopyWhileTheKeychainIsLocked() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(details, forKey: Constants.StorageKeys.Auth.userData)
        let keychain = MemoryKeychain()
        keychain.failure = .unavailable

        let older = CachedUserDataStore(keychain: keychain, defaults: defaults).load()
        #expect(older?.data == details)
        #expect(older?.isFromOlderVersion == true)
        #expect(defaults.data(forKey: Constants.StorageKeys.Auth.userData) == details)
    }

    @Test func savesOnlyToTheKeychain() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()
        let store = CachedUserDataStore(keychain: keychain, defaults: defaults)

        store.save(details)
        // The details are saved off this thread; a read waits for them.
        #expect(store.load()?.isFromOlderVersion == false)
        #expect(keychain.items[item] == details)
        #expect(defaults.object(forKey: Constants.StorageKeys.Auth.userData) == nil)

        store.clear()
        #expect(keychain.items[item] == nil)
    }

    @Test func aSecondStoreReadsWhatTheFirstIsStillSaving() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let keychain = MemoryKeychain()

        CachedUserDataStore(keychain: keychain, defaults: defaults).save(details)
        let read = CachedUserDataStore(keychain: keychain, defaults: defaults).load()
        #expect(read?.data == details)
    }

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let name = "CachedUserDataStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }
}
