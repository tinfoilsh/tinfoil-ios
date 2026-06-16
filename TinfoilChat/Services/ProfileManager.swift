//
//  ProfileManager.swift
//  TinfoilChat
//
//  Manages user profile settings with Keychain storage and cloud sync
//

import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    static let profileSharedSettingsDidChange = Notification.Name("com.tinfoil.chat.profile.shared-settings-did-change")
}

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    
    // Published properties for UI binding
    @Published var isDarkMode: Bool = true
    @Published var language: String = "English"
    
    // Personalization settings
    @Published var nickname: String = ""
    @Published var profession: String = ""
    @Published var traits: [String] = []
    @Published var additionalContext: String = ""
    @Published var isUsingPersonalization: Bool = false
    
    // Custom system prompt
    @Published var isUsingCustomPrompt: Bool = false
    @Published var customSystemPrompt: String = ""

    // User-created prompt presets (synced through the shared profile row)
    @Published var customPromptPresets: [SyncedPromptPreset] = []
    
    // Sync state
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    
    // Private properties
    private let keychainQueue = DispatchQueue(label: "com.tinfoil.chat.profile-keychain")
    private let keychainHelper = KeychainHelper.shared
    private let profileSync = ProfileSyncService.shared
    private var syncTimer: Timer?
    private var syncDebounceTimer: Timer?
    private var syncLoopTask: Task<Void, Never>?
    private var lastSyncedVersion: Int = 0
    private var lastSyncedProfile: ProfileData?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingProfile: Bool = false  // Flag to prevent observer loops
    private var isPulling: Bool = false
    private var isPushing: Bool = false
    private var codeExecutionEnabled: Bool?
    private var piiCheckEnabled: Bool?
    private var chatFont: String?
    private var projectUploadPreference: String?
    
    // Keychain keys
    private let keychainKey = "userProfile"
    private let keychainService = "com.tinfoil.chat.profile"
    private let profileDirtyKey = "com.tinfoil.chat.profile.dirty"
    
    private init() {
        loadFromKeychain()
        setupChangeObservers()
        setupAutoSync()
        // Trigger an initial sync shortly after initialization
        Task { @MainActor in
            await performFullSync()
        }
    }
    
    // MARK: - Local Storage
    
    /// Load profile from Keychain
    private func loadFromKeychain() {
        guard let data = keychainHelper.load(for: keychainKey, service: keychainService),
              let profile = try? JSONDecoder().decode(ProfileData.self, from: data) else {
            // No profile in keychain, use defaults
            return
        }
        
        applyProfile(profile)
        
        // Also update last synced version if profile has one
        if let version = profile.version {
            lastSyncedVersion = version
        }
        // Treat the loaded profile as the last synced baseline
        if !hasPendingLocalProfileChanges {
            lastSyncedProfile = profile
        }
    }
    
    /// Save profile to Keychain
    private func saveToKeychain() {
        let profile = createProfileData()

        persistProfileToKeychain(profile)

        // Only treat this as a local edit when the content actually
        // diverges from the last synced baseline. Debounced observers
        // can fire after `isApplyingProfile` has reset following a
        // cloud apply, which would otherwise mark the profile dirty and
        // wedge future pulls behind a phantom pending change.
        if !isApplyingProfile && hasProfileChanged(profile, lastSyncedProfile) {
            markLocalProfileChanged()
            if !isSyncing {
                debounceCloudSync()
            } else {
                // If a sync is running, we'll re-check after it finishes
            }
        }
    }

    private var hasPendingLocalProfileChanges: Bool {
        UserDefaults.standard.bool(forKey: profileDirtyKey)
    }

    private func markLocalProfileChanged() {
        UserDefaults.standard.set(true, forKey: profileDirtyKey)
    }

    private func clearLocalProfileChanged() {
        UserDefaults.standard.removeObject(forKey: profileDirtyKey)
    }

    private func persistProfileToKeychain(_ profile: ProfileData) {
        guard let data = try? JSONEncoder().encode(profile) else {
            return
        }

        let helper = keychainHelper
        let key = keychainKey
        let service = keychainService
        keychainQueue.async {
            helper.save(data, for: key, service: service)
        }
    }
    
    /// Create ProfileData from current settings
    private func createProfileData() -> ProfileData {
        let selectedModel = AppConfig.shared.currentModel?.id
            ?? UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.selectedModel)
        let reasoningEffort = UserDefaults.standard.string(
            forKey: Constants.StorageKeys.Settings.reasoningEffort
        ) ?? ReasoningEffort.medium.rawValue
        let thinkingEnabled: Bool
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.thinkingEnabled) != nil {
            thinkingEnabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.Settings.thinkingEnabled)
        } else {
            thinkingEnabled = true
        }

        return ProfileData(
            isDarkMode: isDarkMode,
            language: language,
            nickname: nickname,
            profession: profession,
            traits: traits,
            additionalContext: additionalContext,
            isUsingPersonalization: isUsingPersonalization,
            isUsingCustomPrompt: isUsingCustomPrompt,
            customSystemPrompt: customSystemPrompt,
            customPromptPresets: customPromptPresets.isEmpty ? nil : customPromptPresets,
            selectedModel: selectedModel,
            reasoningEffort: reasoningEffort,
            thinkingEnabled: thinkingEnabled,
            webSearchEnabled: SettingsManager.shared.webSearchEnabled,
            codeExecutionEnabled: codeExecutionEnabled,
            piiCheckEnabled: piiCheckEnabled,
            chatFont: chatFont,
            projectUploadPreference: projectUploadPreference,
            version: lastSyncedVersion,  // Will be incremented by ProfileSyncService
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
    
    /// Apply profile data to published properties
    private func applyProfile(_ profile: ProfileData) {
        isApplyingProfile = true  // Prevent observer loops
        
        if let isDarkMode = profile.isDarkMode {
            self.isDarkMode = isDarkMode
        }
        if let language = profile.language {
            self.language = language
        }
        if let nickname = profile.nickname {
            self.nickname = nickname
        }
        if let profession = profile.profession {
            self.profession = profession
        }
        if let traits = profile.traits {
            self.traits = traits
        }
        if let additionalContext = profile.additionalContext {
            self.additionalContext = additionalContext
        }
        if let isUsingPersonalization = profile.isUsingPersonalization {
            self.isUsingPersonalization = isUsingPersonalization
        }
        if let isUsingCustomPrompt = profile.isUsingCustomPrompt {
            self.isUsingCustomPrompt = isUsingCustomPrompt
        }
        if let customSystemPrompt = profile.customSystemPrompt {
            self.customSystemPrompt = customSystemPrompt
        }
        if let customPromptPresets = profile.customPromptPresets {
            self.customPromptPresets = customPromptPresets
        }
        if let selectedModel = profile.selectedModel {
            UserDefaults.standard.set(selectedModel, forKey: Constants.StorageKeys.Settings.selectedModel)
            applySelectedModel(selectedModel)
        }
        if let reasoningEffort = profile.reasoningEffort,
           ReasoningEffort(rawValue: reasoningEffort) != nil {
            UserDefaults.standard.set(reasoningEffort, forKey: Constants.StorageKeys.Settings.reasoningEffort)
        }
        if let thinkingEnabled = profile.thinkingEnabled {
            UserDefaults.standard.set(thinkingEnabled, forKey: Constants.StorageKeys.Settings.thinkingEnabled)
        }
        if let webSearchEnabled = profile.webSearchEnabled {
            SettingsManager.shared.webSearchEnabled = webSearchEnabled
        }
        if let codeExecutionEnabled = profile.codeExecutionEnabled {
            self.codeExecutionEnabled = codeExecutionEnabled
        }
        if let piiCheckEnabled = profile.piiCheckEnabled {
            self.piiCheckEnabled = piiCheckEnabled
        }
        if let chatFont = profile.chatFont {
            self.chatFont = chatFont
        }
        if let projectUploadPreference = profile.projectUploadPreference {
            self.projectUploadPreference = projectUploadPreference
        }
        if let version = profile.version {
            self.lastSyncedVersion = version
        }

        NotificationCenter.default.post(
            name: .profileSharedSettingsDidChange,
            object: profile
        )

        isApplyingProfile = false  // Re-enable observers
    }

    private func applySelectedModel(_ modelId: String) {
        guard let model = AppConfig.shared.availableModels.first(where: { $0.id == modelId }) else {
            return
        }
        AppConfig.shared.currentModel = model
    }
    
    // MARK: - Change Observers
    
    private func setupChangeObservers() {
        // Observe all published properties for changes
        $isDarkMode
            .dropFirst()
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        
        $language
            .dropFirst()
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $nickname
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $profession
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $traits
            .dropFirst()
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $additionalContext
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $isUsingPersonalization
            .dropFirst()
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $isUsingCustomPrompt
            .dropFirst()
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
        
        $customSystemPrompt
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)

        $customPromptPresets
            .dropFirst()
            .sink { [weak self] _ in
                guard !(self?.isApplyingProfile ?? false) else { return }
                self?.saveToKeychain()
            }
            .store(in: &cancellables)
    }

    // MARK: - Prompt Presets

    /// All presets surfaced in the prompt library: built-ins followed by the
    /// user's custom presets.
    var allPromptPresets: [PromptPreset] {
        PromptPreset.builtIns + customPromptPresets.map { PromptPreset(from: $0) }
    }

    /// Resolve a preset by id across built-ins and user presets.
    func promptPreset(for id: String?) -> PromptPreset? {
        guard let id else { return nil }
        return allPromptPresets.first { $0.id == id }
    }

    private func generatePresetId() -> String {
        let random = UUID().uuidString.prefix(8).lowercased()
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        return "\(PromptPreset.userIdPrefix)\(timestamp)-\(random)"
    }

    /// Create a new user preset and return its library representation.
    @discardableResult
    func createPromptPreset(name: String, description: String, systemPrompt: String) -> PromptPreset {
        let now = Date().timeIntervalSince1970 * 1000
        let preset = SyncedPromptPreset(
            id: generatePresetId(),
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            createdAt: now,
            updatedAt: now
        )
        customPromptPresets.append(preset)
        return PromptPreset(from: preset)
    }

    /// Update an existing user preset in place.
    func updatePromptPreset(id: String, name: String, description: String, systemPrompt: String) {
        guard let index = customPromptPresets.firstIndex(where: { $0.id == id }) else { return }
        customPromptPresets[index].name = name
        customPromptPresets[index].description = description
        customPromptPresets[index].systemPrompt = systemPrompt
        customPromptPresets[index].updatedAt = Date().timeIntervalSince1970 * 1000
    }

    /// Delete a user preset.
    func deletePromptPreset(id: String) {
        customPromptPresets.removeAll { $0.id == id }
    }

    /// Duplicate a built-in or user preset into a new editable user preset.
    @discardableResult
    func duplicatePromptPreset(id: String) -> PromptPreset? {
        guard let source = promptPreset(for: id) else { return nil }
        return createPromptPreset(
            name: "\(source.name) (copy)",
            description: source.description,
            systemPrompt: source.systemPrompt
        )
    }
    
    // MARK: - Cloud Sync
    
    /// Setup automatic sync timer
    private func setupAutoSync() {
        // Cancel any existing timers/tasks
        syncTimer?.invalidate()
        syncLoopTask?.cancel()

        // Use an async loop to avoid RunLoop mode issues
        let intervalNanoseconds = UInt64(Constants.Sync.profileSyncIntervalSeconds * 1_000_000_000)
        syncLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                await self.performFullSync()
            }
        }
    }
    
    /// Debounce cloud sync after local changes
    private func debounceCloudSync() {
        syncDebounceTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.syncToCloud()
            }
        }
        syncDebounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateSyncingState() {
        isSyncing = isPulling || isPushing
    }
    
    /// Sync profile from cloud
    func syncFromCloud() async {
        // Skip if not authenticated
        guard await profileSync.isAuthenticated() else {
            return
        }

        // Skip if no encryption key is set
        guard EncryptionService.shared.hasEncryptionKey() else {
            return
        }

        guard !hasPendingLocalProfileChanges else {
            return
        }

        // Prevent overlapping pulls
        guard !isPulling else { return }
        isPulling = true
        updateSyncingState()
        
        do {
            if let cloudProfile = try await profileSync.fetchProfile() {
                let cloudVersion = cloudProfile.version ?? 0
                
                // Apply if cloud is newer by version OR content differs from our last-synced snapshot
                if cloudVersion > lastSyncedVersion || hasProfileChanged(cloudProfile, lastSyncedProfile) {
                    applyProfile(cloudProfile)
                    
                    // Save to keychain without triggering local change observers
                    persistProfileToKeychain(cloudProfile)
                    
                    lastSyncedVersion = cloudVersion
                    lastSyncedProfile = cloudProfile
                    clearLocalProfileChanged()
                    lastSyncDate = Date()
                    syncError = nil
                }
            }
        } catch {
            syncError = error.localizedDescription
        }
        
        isPulling = false
        updateSyncingState()
    }
    
    /// Sync profile to cloud
    func syncToCloud() async {
        // Skip if not authenticated but keep pending flag so we can retry later
        guard await profileSync.isAuthenticated() else {
            return
        }

        // Skip if no encryption key is set
        guard EncryptionService.shared.hasEncryptionKey() else {
            return
        }

        let authorizationMode = CloudKeyAuthorizationStore.shared.currentMode()
        guard authorizationMode != nil else {
            return
        }

        if profileSync.hasFailedRemoteDecryption(),
           authorizationMode != .explicitStartFresh {
            return
        }

        // Avoid overlapping uploads
        guard !isPushing else { return }
        
        let profile = createProfileData()
        
        // Only push if there is a real change vs last synced baseline.
        // When nothing diverges, clear the pending flag so a phantom
        // dirty marker can't permanently block pulls from the cloud.
        guard hasProfileChanged(profile, lastSyncedProfile) else {
            clearLocalProfileChanged()
            return
        }
        
        isPushing = true
        updateSyncingState()
        
        do {
            let result = try await profileSync.saveProfile(profile)
            if result.success {
                // Server returns the authoritative version; always adopt it
                if let version = result.version {
                    lastSyncedVersion = version
                } else {
                    // Fallback: ensure we at least bump our local version
                    lastSyncedVersion = (profile.version ?? lastSyncedVersion) + 1
                }
                var syncedProfile = profile
                syncedProfile.version = lastSyncedVersion
                lastSyncedProfile = syncedProfile
                persistProfileToKeychain(syncedProfile)
                clearLocalProfileChanged()
                lastSyncDate = Date()
                syncError = nil
                
                // If local state changed during the sync, schedule another upload
                let currentAfter = createProfileData()
                if hasProfileChanged(currentAfter, lastSyncedProfile) {
                    debounceCloudSync()
                }
            }
        } catch {
            syncError = error.localizedDescription
            // On error, allow future changes to trigger another attempt via debounce
        }
        
        isPushing = false
        updateSyncingState()
    }
    
    /// Perform immediate sync (both directions)
    func performFullSync() async {
        // First pull from cloud
        await syncFromCloud()
        
        // Then push any local changes (method will no-op if nothing changed)
        await syncToCloud()
    }
    
    /// Retry decryption with new encryption key
    func retryDecryptionWithNewKey() async {
        do {
            if let decryptedProfile = try await profileSync.retryDecryptionWithNewKey() {
                applyProfile(decryptedProfile)
                persistProfileToKeychain(decryptedProfile)
                if let version = decryptedProfile.version {
                    lastSyncedVersion = version
                }
                lastSyncedProfile = decryptedProfile
                clearLocalProfileChanged()
                syncError = nil
            }
        } catch {
            syncError = error.localizedDescription
        }
    }
    
    // MARK: - Helpers
    
    /// Check if two profiles are different (excluding metadata)
    private func hasProfileChanged(_ profile1: ProfileData?, _ profile2: ProfileData?) -> Bool {
        guard let p1 = profile1, let p2 = profile2 else {
            return profile1 != nil || profile2 != nil
        }
        
        return p1.isDarkMode != p2.isDarkMode ||
               p1.language != p2.language ||
               p1.nickname != p2.nickname ||
               p1.profession != p2.profession ||
               p1.traits != p2.traits ||
               p1.additionalContext != p2.additionalContext ||
               p1.isUsingPersonalization != p2.isUsingPersonalization ||
               p1.isUsingCustomPrompt != p2.isUsingCustomPrompt ||
               p1.customSystemPrompt != p2.customSystemPrompt ||
               p1.customPromptPresets != p2.customPromptPresets ||
               p1.selectedModel != p2.selectedModel ||
               p1.reasoningEffort != p2.reasoningEffort ||
               p1.thinkingEnabled != p2.thinkingEnabled ||
               p1.webSearchEnabled != p2.webSearchEnabled ||
               p1.codeExecutionEnabled != p2.codeExecutionEnabled ||
               p1.piiCheckEnabled != p2.piiCheckEnabled ||
               p1.chatFont != p2.chatFont ||
               p1.projectUploadPreference != p2.projectUploadPreference
    }

    func sharedSettingsDidChange() {
        saveToKeychain()
    }
    
    /// Generate personalization prompt for chat as a `<user_preferences>` XML block.
    ///
    /// Mirrors the webapp's `useCustomSystemPrompt` so the same prompt structure
    /// reaches the model regardless of platform. The `isUsingPersonalization`
    /// flag is treated as a soft preference — if the user has filled in fields
    /// we still inject them, since the most common cause of "the model doesn't
    /// know my name" is the flag not having flipped to true (e.g. cross-device
    /// sync, restore from cloud, edit-without-save). "Reset All" clears the
    /// fields outright, which makes this method return `nil` naturally.
    func getPersonalizationPrompt() -> String? {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProfession = profession.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyTraits = traits.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let trimmedContext = additionalContext.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasAnyField = !trimmedNickname.isEmpty
            || !trimmedProfession.isEmpty
            || !nonEmptyTraits.isEmpty
            || !trimmedContext.isEmpty

        guard hasAnyField else { return nil }

        var xml = "The user has provided personal preferences for this conversation. Adapt your responses according to these settings while maintaining accuracy and helpfulness.\n\n<user_preferences>"

        if !trimmedNickname.isEmpty {
            xml += "\n  <nickname>\(trimmedNickname)</nickname>"
        }

        if !trimmedProfession.isEmpty {
            xml += "\n  <profession>\(trimmedProfession)</profession>"
        }

        if !nonEmptyTraits.isEmpty {
            xml += "\n  <traits>"
            for trait in nonEmptyTraits {
                xml += "\n    <trait>\(trait)</trait>"
            }
            xml += "\n  </traits>"
        }

        if !trimmedContext.isEmpty {
            xml += "\n  <additional_context>\n    \(trimmedContext)\n  </additional_context>"
        }

        xml += "\n</user_preferences>"

        return xml
    }
    
    /// Get custom system prompt if enabled
    func getCustomSystemPrompt() -> String? {
        guard isUsingCustomPrompt, !customSystemPrompt.isEmpty else { return nil }
        return customSystemPrompt
    }
    
    /// Clear all profile data
    func clearProfile() {
        // Reset to defaults
        isDarkMode = true
        language = "English"
        nickname = ""
        profession = ""
        traits = []
        additionalContext = ""
        isUsingPersonalization = false
        isUsingCustomPrompt = false
        customSystemPrompt = ""
        customPromptPresets = []
        
        // Clear from keychain
        keychainHelper.delete(for: keychainKey, service: keychainService)
        
        // Reset sync state
        lastSyncedVersion = 0
        lastSyncedProfile = nil
        syncError = nil
        clearLocalProfileChanged()
        
        // Clear cloud cache
        profileSync.clearCache()
    }
}