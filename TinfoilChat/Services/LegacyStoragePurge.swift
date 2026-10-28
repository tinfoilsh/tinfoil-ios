import Foundation
import OSLog

/// Removes what older clients kept on this device that nothing reads any
/// more, once, at launch. A step that fails, as while the device is
/// locked, leaves the purge to run again on the next launch; every step
/// may run again.
enum LegacyStoragePurge {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Storage")
    static let completedKey = "tinfoil-settings-legacy-storage-purged"

    static func purgeIfNeeded(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainHelper.shared
    ) {
        guard !defaults.bool(forKey: completedKey) else { return }
        let removed = [
            // The passkey PRF output the kit kept after each ceremony.
            keychain.delete(for: Constants.Passkey.prfCacheKeychainAccount, service: Constants.Passkey.rpId),
        ]
        if removed.allSatisfy({ $0 }) {
            defaults.set(true, forKey: completedKey)
        } else {
            logger.error("Some data older versions kept could not be removed yet")
        }
    }
}
