import Foundation
import OSLog

/// The settings this device keeps for the harness: a local profile in the
/// keychain, with its bookkeeping in the defaults.
final class DeviceProfileStorage: ProfileStorage {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    private let keychain: KeychainHelper
    private let defaults: UserDefaults
    private let service = Constants.Harness.Profile.keychainService

    init(keychain: KeychainHelper = .shared, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// The first read imports the settings the previous client kept, once;
    /// afterwards only the local profile is read.
    func loadLocalProfile() -> ProfileFields {
        if let data = keychain.load(for: Constants.Harness.Profile.localProfileKey, service: service) {
            return Self.object(data) ?? [:]
        }
        let imported = PreviousClientSettings.profile(keychain: keychain, defaults: defaults)
        if !imported.isEmpty { write(imported) }
        return imported
    }

    func saveLocalProfile(_ patch: ProfileFields, replace: Bool) -> ProfileFields {
        var profile = replace ? [:] : loadLocalProfile()
        profile.merge(patch) { $1 }
        profile = profile.filter { !($0.value is NSNull) }
        write(profile)
        if !replace {
            let changed = Set(localProfileChanges()).union(patch.keys)
            defaults.set(Array(changed).sorted(), forKey: Constants.Harness.Profile.localProfileChangesKey)
        }
        return profile
    }

    func localProfileChanges() -> [String] {
        defaults.stringArray(forKey: Constants.Harness.Profile.localProfileChangesKey) ?? []
    }

    func clearLocalProfileChanges() {
        defaults.removeObject(forKey: Constants.Harness.Profile.localProfileChangesKey)
    }

    var localProfileUpgraded: Bool {
        get { defaults.bool(forKey: Constants.Harness.Profile.localProfileUpgradedKey) }
        set { defaults.set(newValue, forKey: Constants.Harness.Profile.localProfileUpgradedKey) }
    }

    var pendingProfileMerge: String? {
        get { defaults.string(forKey: Constants.Harness.Profile.pendingProfileMergeKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Constants.Harness.Profile.pendingProfileMergeKey)
            } else {
                defaults.removeObject(forKey: Constants.Harness.Profile.pendingProfileMergeKey)
            }
        }
    }

    func cloudProfileCache(userId: String?) -> ProfileFields {
        guard let userId, let data = keychain.load(for: Self.cloudCacheKey(userId), service: service) else { return [:] }
        return Self.object(data) ?? [:]
    }

    func saveCloudProfileCache(_ profile: ProfileFields, userId: String?) {
        guard let userId, let data = Self.data(profile) else { return }
        keychain.save(data, for: Self.cloudCacheKey(userId), service: service)
    }

    func clearCloudProfileCache(userId: String?) {
        guard let userId else { return }
        keychain.delete(for: Self.cloudCacheKey(userId), service: service)
    }

    private static func cloudCacheKey(_ userId: String) -> String {
        Constants.Harness.Profile.cloudProfileCacheKeyPrefix + userId
    }

    private func write(_ profile: ProfileFields) {
        guard let data = Self.data(profile), keychain.save(data, for: Constants.Harness.Profile.localProfileKey, service: service) else {
            Self.logger.error("Failed to save local settings")
            return
        }
    }

    private static func object(_ data: Data) -> ProfileFields? {
        (try? JSONSerialization.jsonObject(with: data)) as? ProfileFields
    }

    private static func data(_ profile: ProfileFields) -> Data? {
        try? JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    }
}

/// The settings the previous client kept on this device, in the harness
/// profile's field names: its profile in the keychain, and the settings it
/// kept in the defaults. The harness upgrades them once, and reads only the
/// fields it knows.
enum PreviousClientSettings {
    /// The members of the previous client's profile that are the harness's.
    private static let profileFields = [
        "themeMode", "language", "nickname", "profession", "traits", "additionalContext", "isUsingPersonalization",
        "customPromptPresets", "favoritePromptPresetIds", "defaultPromptPresetId", "reasoningEffort", "thinkingEnabled",
        "webSearchAvailable", "piiCheckEnabled", "genUIEnabled", "chatFont",
    ]

    static func profile(keychain: KeychainHelper, defaults: UserDefaults) -> ProfileFields {
        var fields: ProfileFields = [:]
        if let data = keychain.load(for: Constants.Harness.Profile.previousProfileKey, service: Constants.Harness.Profile.keychainService),
           let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for name in profileFields {
                if let value = stored[name], !(value is NSNull) { fields[name] = value }
            }
            if fields["themeMode"] == nil, let dark = stored["isDarkMode"] as? Bool { fields["themeMode"] = dark ? "dark" : "light" }
        }
        let settings = Constants.StorageKeys.Settings.self
        if let model = defaults.string(forKey: settings.selectedModel) { fields["selectedModel"] = model }
        if let level = defaults.object(forKey: settings.autoIntelligence) { fields["autoIntelligence"] = "\(level)" }
        if let effort = defaults.string(forKey: settings.reasoningEffort) { fields["reasoningEffort"] = effort }
        if defaults.object(forKey: settings.thinkingEnabled) != nil { fields["thinkingEnabled"] = defaults.bool(forKey: settings.thinkingEnabled) }
        if defaults.object(forKey: settings.webSearchEnabled) != nil { fields["webSearchEnabled"] = defaults.bool(forKey: settings.webSearchEnabled) }
        if defaults.object(forKey: settings.webSearchAvailable) != nil { fields["webSearchAvailable"] = defaults.bool(forKey: settings.webSearchAvailable) }
        if defaults.object(forKey: settings.piiCheckEnabled) != nil { fields["piiCheckEnabled"] = defaults.bool(forKey: settings.piiCheckEnabled) }
        if defaults.object(forKey: settings.genUIEnabled) != nil { fields["genUIEnabled"] = defaults.bool(forKey: settings.genUIEnabled) }
        return fields
    }
}
