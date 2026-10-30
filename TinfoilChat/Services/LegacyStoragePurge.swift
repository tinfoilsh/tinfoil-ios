import Foundation
import OSLog

/// Removes what older clients kept on this device that nothing reads any
/// more: once at launch, and an account's own as it signs out. A step that
/// fails, as while the device is locked, leaves the launch purge to run
/// again on the next launch; every step may run again.
enum LegacyStoragePurge {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Storage")
    static let completedKey = "tinfoil-settings-legacy-storage-purged"

    /// The previous client's profile sync bookkeeping, in the profile's
    /// keychain service.
    private static let profileKeychainKeys = ["userProfileSyncBaseline", "profileUnknownFields"]
    /// The previous client's prompt cache secret, by account, in the
    /// default keychain service.
    private static let promptCacheSecretPrefix = "chat-recovery-user-cache-secret-"
    /// The previous client's cache of the account's project list, under
    /// Application Support.
    private static let projectCacheDirectory = "tinfoil/projects"
    private static let defaultsKeys = [
        "tinfoil-sync-device-id",
        "tinfoil-sync-edit-clock",
        "com.tinfoil.chat.profile.dirty",
        "com.tinfoil.chat.profile.changed-at",
        // Personalization older clients kept in plain text beside the
        // profile, which holds it.
        Constants.StorageKeys.UserPrefs.nickname,
        Constants.StorageKeys.UserPrefs.profession,
        Constants.StorageKeys.UserPrefs.traits,
        Constants.StorageKeys.UserPrefs.additionalContext,
    ]
    /// The previous client's sync state and key authorization, each key
    /// ending in the account's id.
    private static let accountDefaultsPrefixes = [
        "tinfoil-sync-revision-checkpoint-v2-",
        "tinfoil-sync-last-sync-date-",
        "tinfoil-sync-pagination-token-",
        "tinfoil-sync-pagination-has-more-",
        "tinfoil-sync-pagination-active-",
        "tinfoil-sync-pagination-loaded-first-",
        "tinfoil-sync-pagination-attempted-",
        "tinfoil-migration-legacy-cloud-chats-evicted_",
        "tinfoil-secret-cloud-key-authorization-",
    ]

    static func purgeIfNeeded(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainHelper.shared,
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) {
        guard !defaults.bool(forKey: completedKey) else { return }
        for key in defaults.dictionaryRepresentation().keys
            where defaultsKeys.contains(key) || accountDefaultsPrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        let removed = [
            // The passkey PRF output the kit kept after each ceremony.
            keychain.delete(for: Constants.Passkey.prfCacheKeychainAccount, service: Constants.Passkey.rpId),
            profileKeychainKeys.map { keychain.delete(for: $0, service: Constants.Harness.Profile.keychainService) }.allSatisfy { $0 },
            removePromptCacheSecrets(keychain: keychain),
            removeImportedPreviousProfile(keychain: keychain, defaults: defaults),
            removeProjectCache(applicationSupport: applicationSupport),
        ]
        if removed.allSatisfy({ $0 }) {
            defaults.set(true, forKey: completedKey)
        } else {
            logger.error("Some data older versions kept could not be removed yet")
        }
    }

    /// Removes what the previous client kept for an account, as it signs
    /// out.
    static func purge(
        userId: String,
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainHelper.shared
    ) {
        for prefix in accountDefaultsPrefixes {
            defaults.removeObject(forKey: prefix + userId)
        }
        keychain.delete(for: promptCacheSecretPrefix + userId, service: nil)
    }

    private static func removePromptCacheSecrets(keychain: KeychainStore) -> Bool {
        do {
            return try keychain.keys(service: nil)
                .filter { $0.hasPrefix(promptCacheSecretPrefix) }
                .map { keychain.delete(for: $0, service: nil) }
                .allSatisfy { $0 }
        } catch {
            logger.error("Failed to list the old prompt cache secrets: \(error, privacy: .public)")
            return false
        }
    }

    /// The previous client's profile goes once it was imported, which the
    /// local profile it was imported into shows, or when the previous client
    /// never ran in this install. One not yet imported is kept for its
    /// import.
    private static func removeImportedPreviousProfile(keychain: KeychainStore, defaults: UserDefaults) -> Bool {
        guard PreviousClientSettings.ranInThisInstall(defaults: defaults) else {
            return keychain.delete(for: Constants.Harness.Profile.previousProfileKey, service: Constants.Harness.Profile.keychainService)
        }
        do {
            guard try keychain.load(for: Constants.Harness.Profile.localProfileKey, service: Constants.Harness.Profile.keychainService) != nil else {
                return true
            }
        } catch {
            return false
        }
        return keychain.delete(for: Constants.Harness.Profile.previousProfileKey, service: Constants.Harness.Profile.keychainService)
    }

    private static func removeProjectCache(applicationSupport: URL?) -> Bool {
        guard let applicationSupport else { return true }
        do {
            try FileManager.default.removeItem(at: applicationSupport.appendingPathComponent(projectCacheDirectory, isDirectory: true))
        } catch CocoaError.fileNoSuchFile {
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
        } catch {
            logger.error("Failed to remove the old project cache: \(error, privacy: .public)")
            return false
        }
        return true
    }
}
