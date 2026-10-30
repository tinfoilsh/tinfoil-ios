import Foundation
import OSLog

/// The settings this device keeps for the harness: a local profile in the
/// keychain, with its bookkeeping in the defaults.
final class DeviceProfileStorage: ProfileStorage {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    /// The members of the stored local profile: the install that stored it,
    /// and its fields.
    private static let installMember = "installId"
    private static let profileMember = "profile"

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let service = Constants.Harness.Profile.keychainService

    init(keychain: KeychainStore = KeychainHelper.shared, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// The first read imports the settings the previous client kept, once,
    /// and removes its profile once the import is kept; afterwards only the
    /// local profile is read. A stored profile that cannot be decoded is
    /// logged and shown as empty, without an import; a keychain that cannot
    /// be read, as while the device is locked, fails the read. Keychain
    /// items outlive the app, so a profile stored by another install, or by
    /// none, is one a deleted install left: it is removed, and read as none.
    func loadLocalProfile() throws -> ProfileFields {
        if let data = try keychain.load(for: Constants.Harness.Profile.localProfileKey, service: service) {
            guard let stored = Self.object(data) else {
                Self.logger.error("The local settings could not be read")
                return [:]
            }
            if stored[Self.installMember] as? String == installId {
                guard let profile = stored[Self.profileMember] as? ProfileFields else {
                    Self.logger.error("The local settings could not be read")
                    return [:]
                }
                return profile
            }
            keychain.delete(for: Constants.Harness.Profile.localProfileKey, service: service)
        }
        let imported = try PreviousClientSettings.profile(keychain: keychain, defaults: defaults)
        if !imported.isEmpty {
            do {
                try write(imported)
                keychain.delete(for: Constants.Harness.Profile.previousProfileKey, service: service)
            } catch {
                Self.logger.error("Failed to keep the imported settings: \(error, privacy: .public)")
            }
        }
        return imported
    }

    func saveLocalProfile(_ patch: ProfileFields, replace: Bool) throws -> ProfileFields {
        var profile = replace ? [:] : try loadLocalProfile()
        profile.merge(patch) { $1 }
        profile = profile.filter { !($0.value is NSNull) }
        try write(profile)
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

    /// Forgets the local profile and its bookkeeping, as when the account is
    /// removed.
    func clearLocalProfile() {
        keychain.delete(for: Constants.Harness.Profile.localProfileKey, service: service)
        keychain.delete(for: Constants.Harness.Profile.previousProfileKey, service: service)
        clearLocalProfileChanges()
        localProfileUpgraded = false
        pendingProfileMerge = nil
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

    /// The cloud profile last seen, shown until the harness's loads; none
    /// when it cannot be read.
    func cloudProfileCache(userId: String?) -> ProfileFields {
        guard let userId else { return [:] }
        do {
            guard let data = try keychain.load(for: Self.cloudCacheKey(userId), service: service) else { return [:] }
            return Self.object(data) ?? [:]
        } catch {
            Self.logger.error("Failed to read the cloud settings kept on this device: \(error, privacy: .public)")
            return [:]
        }
    }

    func saveCloudProfileCache(_ profile: ProfileFields, userId: String?) {
        guard let userId, let data = Self.data(profile) else { return }
        do {
            try keychain.save(data, for: Self.cloudCacheKey(userId), service: service)
        } catch {
            Self.logger.error("Failed to keep the cloud settings on this device: \(error, privacy: .public)")
        }
    }

    func clearCloudProfileCache(userId: String?) {
        guard let userId else { return }
        keychain.delete(for: Self.cloudCacheKey(userId), service: service)
    }

    private static func cloudCacheKey(_ userId: String) -> String {
        Constants.Harness.Profile.cloudProfileCacheKeyPrefix + userId
    }

    private func write(_ profile: ProfileFields) throws {
        let stored: ProfileFields = [Self.installMember: installId, Self.profileMember: profile]
        guard let data = Self.data(stored), (try? keychain.save(data, for: Constants.Harness.Profile.localProfileKey, service: service)) != nil else {
            throw HarnessError(code: HarnessErrorCode.localSaveFailed, message: "Your settings could not be saved on this device.", action: .retry)
        }
    }

    /// This install's id, made on first use and kept in the defaults, which
    /// go with the app.
    private var installId: String {
        if let id = defaults.string(forKey: Constants.Harness.Profile.installIdKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Constants.Harness.Profile.installIdKey)
        return id
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
        "isUsingCustomPrompt", "customSystemPrompt", "customPromptPresets", "favoritePromptPresetIds", "defaultPromptPresetId",
        "reasoningEffort", "thinkingEnabled", "webSearchAvailable", "piiCheckEnabled", "genUIEnabled", "chatFont",
    ]

    /// Whether the previous client ran in this install, and so kept the
    /// profile the keychain holds. Every previous client kept the response
    /// language in the defaults from its first launch, and this client keeps
    /// none; the defaults go with the app while the keychain outlives it, so
    /// a profile found without the language was left by a deleted install.
    static func ranInThisInstall(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Constants.StorageKeys.Settings.selectedLanguage) != nil
    }

    static func profile(keychain: KeychainStore, defaults: UserDefaults) throws -> ProfileFields {
        var fields: ProfileFields = [:]
        if ranInThisInstall(defaults: defaults),
           let data = try keychain.load(for: Constants.Harness.Profile.previousProfileKey, service: Constants.Harness.Profile.keychainService),
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
        // Clients before the web search setting kept one web search toggle
        // for every chat, which new chats start with.
        if defaults.object(forKey: settings.webSearchEnabled) != nil { fields["webSearchEnabled"] = defaults.bool(forKey: settings.webSearchEnabled) }
        if defaults.object(forKey: settings.webSearchAvailable) != nil { fields["webSearchAvailable"] = defaults.bool(forKey: settings.webSearchAvailable) }
        if defaults.object(forKey: settings.piiCheckEnabled) != nil { fields["piiCheckEnabled"] = defaults.bool(forKey: settings.piiCheckEnabled) }
        if defaults.object(forKey: settings.genUIEnabled) != nil { fields["genUIEnabled"] = defaults.bool(forKey: settings.genUIEnabled) }
        // The custom prompt setting older clients mirrored outside the
        // profile, which the harness turns into a saved prompt.
        let prefs = Constants.StorageKeys.UserPrefs.self
        if fields["isUsingCustomPrompt"] == nil, defaults.object(forKey: prefs.customPromptEnabled) != nil {
            fields["isUsingCustomPrompt"] = defaults.bool(forKey: prefs.customPromptEnabled)
        }
        if fields["customSystemPrompt"] == nil, let prompt = defaults.string(forKey: prefs.customSystemPrompt) {
            fields["customSystemPrompt"] = prompt
        }
        return fields
    }
}
