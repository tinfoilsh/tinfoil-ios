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

    // Preset ids pinned as homescreen favorites (built-in or custom)
    @Published var favoritePromptPresetIds: [String] = []
    
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
    private var isFullSyncInProgress: Bool = false
    private var fullSyncWaiters: [CheckedContinuation<Void, Never>] = []
    private var accountGeneration: Int = 0
    private var themeMode: String?
    private var localFieldClocks: [String: EditClock]?
    private var localClockVersion: Int?
    private var codeExecutionEnabled: Bool?
    private var piiCheckEnabled: Bool?
    private var chatFont: String?
    private var projectUploadPreference: String?
    
    // Keychain keys
    private let keychainKey = "userProfile"
    private let profileBaselineKey = "userProfileSyncBaseline"
    private let keychainService = "com.tinfoil.chat.profile"
    private let profileDirtyKey = "com.tinfoil.chat.profile.dirty"
    // Content modification time of the pending local profile edit, used
    // to arbitrate last-write-wins against a concurrently-updated remote.
    private let profileChangedAtKey = "com.tinfoil.chat.profile.changed-at"
    
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
        if let baselineData = keychainHelper.load(
            for: profileBaselineKey,
            service: keychainService
        ), let baseline = try? JSONDecoder().decode(ProfileData.self, from: baselineData) {
            lastSyncedProfile = baseline
            lastSyncedVersion = baseline.version ?? lastSyncedVersion
        } else if !hasPendingLocalProfileChanges {
            lastSyncedProfile = profile
            persistBaselineToKeychain(profile)
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
        UserDefaults.standard.set(
            ProfileManager.iso8601Formatter.string(from: Date()),
            forKey: profileChangedAtKey
        )
    }

    private func clearLocalProfileChanged() {
        UserDefaults.standard.removeObject(forKey: profileDirtyKey)
        UserDefaults.standard.removeObject(forKey: profileChangedAtKey)
    }

    /// Edit time of the pending local profile change, used to arbitrate
    /// last-write-wins against the remote. Returns nil when the edit time
    /// is unknown (e.g. a dirty flag left by an older build, or partially
    /// cleared storage) so unknown-age local data cannot win the
    /// arbitration and clobber a genuinely newer remote: conflict
    /// resolution then defers to the remote, while a non-conflicting push
    /// still stamps the current time.
    private func localProfileChangedAt() -> String? {
        if let stored = UserDefaults.standard.string(forKey: profileChangedAtKey),
           ProfileManager.iso8601Formatter.date(from: stored) != nil {
            return stored
        }
        return nil
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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

    private func persistBaselineToKeychain(_ profile: ProfileData) {
        guard let data = try? JSONEncoder().encode(profile) else {
            return
        }

        let helper = keychainHelper
        let key = profileBaselineKey
        let service = keychainService
        keychainQueue.async {
            helper.save(data, for: key, service: service)
        }
    }
    
    /// Create ProfileData from current settings
    private func createProfileData() -> ProfileData {
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
            themeMode: themeMode,
            language: language,
            nickname: nickname,
            profession: profession,
            traits: traits,
            additionalContext: additionalContext,
            isUsingPersonalization: isUsingPersonalization,
            isUsingCustomPrompt: isUsingCustomPrompt,
            customSystemPrompt: customSystemPrompt,
            customPromptPresets: customPromptPresets,
            favoritePromptPresetIds: favoritePromptPresetIds,
            reasoningEffort: reasoningEffort,
            thinkingEnabled: thinkingEnabled,
            webSearchEnabled: SettingsManager.shared.webSearchEnabled,
            codeExecutionEnabled: codeExecutionEnabled,
            piiCheckEnabled: piiCheckEnabled,
            genUIEnabled: SettingsManager.shared.genUIEnabled,
            chatFont: chatFont,
            projectUploadPreference: projectUploadPreference,
            version: lastSyncedVersion,  // Will be incremented by ProfileSyncService
            updatedAt: localProfileChangedAt(),
            fieldClocks: localFieldClocks,
            clockVersion: localClockVersion
        )
    }
    
    /// Apply profile data to published properties
    private func applyProfile(_ profile: ProfileData) {
        isApplyingProfile = true  // Prevent observer loops
        // Suppress SettingsManager's sync callbacks while applying, so writing
        // shared settings here does not re-enter this still-initializing
        // singleton (applyProfile can run from within init).
        SettingsManager.shared.isApplyingSharedProfile = true
        
        if let isDarkMode = profile.isDarkMode {
            self.isDarkMode = isDarkMode
        }
        if let themeMode = profile.themeMode {
            self.themeMode = themeMode
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
        if let favoritePromptPresetIds = profile.favoritePromptPresetIds {
            self.favoritePromptPresetIds = favoritePromptPresetIds
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
        if let genUIEnabled = profile.genUIEnabled {
            SettingsManager.shared.genUIEnabled = genUIEnabled
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
        self.localFieldClocks = profile.fieldClocks
        self.localClockVersion = profile.clockVersion

        NotificationCenter.default.post(
            name: .profileSharedSettingsDidChange,
            object: profile
        )

        SettingsManager.shared.isApplyingSharedProfile = false
        isApplyingProfile = false  // Re-enable observers
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

        $favoritePromptPresetIds
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
        favoritePromptPresetIds.removeAll { $0 == id }
    }

    // MARK: - Favorites

    /// Presets pinned as homescreen favorites, resolved in pinned order.
    /// Ids that no longer resolve (e.g. a deleted custom preset synced from
    /// another device) are skipped.
    var favoritePromptPresets: [PromptPreset] {
        favoritePromptPresetIds.compactMap { promptPreset(for: $0) }
    }

    func isFavoritePreset(_ id: String) -> Bool {
        favoritePromptPresetIds.contains(id)
    }

    /// Whether another preset can still be pinned given the favorites cap.
    /// Capacity is measured against favorites that actually resolve to a
    /// preset, so stale ids (e.g. a custom preset deleted on another device,
    /// or one not yet synced here) never count toward the cap and block
    /// adding a valid favorite.
    var canAddFavorite: Bool {
        favoritePromptPresets.count < Constants.PromptLibrary.maxFavorites
    }

    /// Whether the favorite toggle for a preset should be enabled: already
    /// pinned presets can always be unpinned, others only while under the cap.
    func canToggleFavorite(_ id: String) -> Bool {
        isFavoritePreset(id) || canAddFavorite
    }

    /// Toggle a preset's favorite status. Pinning is ignored once the cap is
    /// reached; unpinning always works.
    func toggleFavoritePreset(_ id: String) {
        if let index = favoritePromptPresetIds.firstIndex(of: id) {
            favoritePromptPresetIds.remove(at: index)
        } else if canAddFavorite {
            favoritePromptPresetIds.append(id)
        }
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
                await self?.performFullSync()
            }
        }
        syncDebounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateSyncingState() {
        isSyncing = isPulling || isPushing
    }

    private func prepareLocalProfileForSync() -> ProfileData {
        var profile = createProfileData()
        let changedFields = ProfileMerge.changedProfileFields(
            local: profile,
            baseline: lastSyncedProfile
        )
        var clocks = profile.fieldClocks ?? lastSyncedProfile?.fieldClocks ?? [:]
        let unstampedFields = changedFields.filter {
            clocks[$0] == lastSyncedProfile?.fieldClocks?[$0]
        }
        if !unstampedFields.isEmpty {
            let tick = EditClockStore.nextClock()
            for field in unstampedFields {
                clocks[field] = tick
            }
        }
        profile.fieldClocks = clocks.isEmpty ? nil : clocks
        profile.clockVersion = lastSyncedVersion
        localFieldClocks = profile.fieldClocks
        localClockVersion = profile.clockVersion
        if !unstampedFields.isEmpty {
            persistProfileToKeychain(profile)
        }
        return profile
    }
    
    /// Sync profile from cloud
    func syncFromCloud() async {
        await performFullSync()
    }

    private func syncFromCloud(generation: Int) async -> Bool {
        // Skip if not authenticated
        guard await profileSync.isAuthenticated() else {
            return false
        }

        // Skip if no encryption key is set
        guard EncryptionService.shared.hasEncryptionKey() else {
            return false
        }

        isPulling = true
        updateSyncingState()
        defer {
            isPulling = false
            updateSyncingState()
        }

        do {
            guard generation == accountGeneration else { return false }
            if let cloudProfile = try await profileSync.fetchProfile() {
                guard generation == accountGeneration else { return false }
                let cloudVersion = cloudProfile.version ?? 0
                let localProfile = hasPendingLocalProfileChanges
                    ? prepareLocalProfileForSync()
                    : createProfileData()

                if let baseline = lastSyncedProfile {
                    let merge = ProfileMerge.mergeProfiles(
                        baseline: baseline,
                        local: localProfile,
                        remote: cloudProfile
                    )
                    guard merge.conflicts.isEmpty else {
                        throw ProfileSyncError.unresolvedConflicts(merge.conflicts)
                    }
                    applyProfile(merge.merged)
                    persistProfileToKeychain(createProfileData())
                    commitSyncedBaseline(cloudProfile, version: cloudVersion)
                    if hasProfileChanged(merge.merged, cloudProfile) {
                        markLocalProfileChanged()
                    } else {
                        clearLocalProfileChanged()
                    }
                } else if hasPendingLocalProfileChanges {
                    throw ProfileSyncError.unresolvedConflicts(
                        ProfileMerge.changedProfileFields(local: localProfile, baseline: nil)
                    )
                } else {
                    applyProfile(cloudProfile)
                    persistProfileToKeychain(createProfileData())
                    commitSyncedBaseline(cloudProfile, version: cloudVersion)
                    clearLocalProfileChanged()
                }
            }
            lastSyncDate = Date()
            syncError = nil
            return true
        } catch {
            guard generation == accountGeneration else { return false }
            syncError = error.localizedDescription
            return false
        }
    }
    
    /// Sync profile to cloud
    func syncToCloud() async {
        await performFullSync()
    }

    private func syncToCloud(generation: Int) async {
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

        guard generation == accountGeneration else { return }
        var profile = prepareLocalProfileForSync()

        // Only push if there is a real change vs last synced baseline.
        // When nothing diverges, clear the pending flag so a phantom
        // dirty marker can't permanently block pulls from the cloud.
        guard hasProfileChanged(profile, lastSyncedProfile) else {
            clearLocalProfileChanged()
            return
        }

        isPushing = true
        updateSyncingState()
        defer {
            isPushing = false
            updateSyncingState()
        }

        do {
            let result = try await profileSync.saveProfile(
                profile,
                baseline: lastSyncedProfile
            )
            guard generation == accountGeneration else { return }
            if result.success {
                // Server returns the authoritative version; always adopt it
                if let version = result.version {
                    lastSyncedVersion = version
                } else {
                    // Fallback: ensure we at least bump our local version
                    lastSyncedVersion = (profile.version ?? lastSyncedVersion) + 1
                }

                if let remoteProfile = result.remoteProfile {
                    // A concurrently-updated device won the last-write
                    // race; adopt its settings locally so both devices
                    // converge instead of keeping our now-stale edit.
                    let postSaveMerge = ProfileMerge.mergeProfiles(
                        baseline: profile,
                        local: createProfileData(),
                        remote: remoteProfile
                    )
                    applyProfile(postSaveMerge.merged)
                    persistProfileToKeychain(createProfileData())
                    commitSyncedBaseline(remoteProfile, version: lastSyncedVersion)
                } else {
                    profile.version = lastSyncedVersion
                    profile.clockVersion = lastSyncedVersion
                    localFieldClocks = profile.fieldClocks
                    localClockVersion = profile.clockVersion
                    persistProfileToKeychain(createProfileData())
                    commitSyncedBaseline(profile, version: lastSyncedVersion)
                }
                let currentAfter = createProfileData()
                if hasProfileChanged(currentAfter, lastSyncedProfile) {
                    markLocalProfileChanged()
                    debounceCloudSync()
                } else {
                    clearLocalProfileChanged()
                }
                lastSyncDate = Date()
                syncError = nil
            }
        } catch {
            guard generation == accountGeneration else { return }
            syncError = error.localizedDescription
            // On error, allow future changes to trigger another attempt via debounce
        }
    }
    
    /// Perform immediate sync (both directions)
    func performFullSync() async {
        if isFullSyncInProgress {
            await withCheckedContinuation { continuation in
                fullSyncWaiters.append(continuation)
            }
            return
        }
        isFullSyncInProgress = true
        defer {
            isFullSyncInProgress = false
            let waiters = fullSyncWaiters
            fullSyncWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let generation = accountGeneration
        // First pull from cloud
        guard await syncFromCloud(generation: generation) else { return }
        
        // Then push any local changes (method will no-op if nothing changed)
        await syncToCloud(generation: generation)
    }
    
    /// Retry decryption with new encryption key
    func retryDecryptionWithNewKey() async {
        await performFullSync()
    }
    
    // MARK: - Helpers

    /// Record `snapshot` as the synced baseline at `version`: stamp the
    /// version, persist it to the keychain (without triggering local
    /// change observers), and set it as the in-memory baseline. The
    /// baseline is the last server state this client observed — the
    /// common ancestor for three-way merges — so callers pass the
    /// fetched remote, or the exact snapshot they just pushed. Passing a
    /// local working copy instead would make its pending edits look
    /// already-synced and let a later pull silently revert them.
    private func commitSyncedBaseline(_ snapshot: ProfileData, version: Int) {
        var baseline = snapshot
        baseline.version = version
        baseline.clockVersion = version
        persistBaselineToKeychain(baseline)
        lastSyncedProfile = baseline
        lastSyncedVersion = version
    }

    /// Check if two profiles are different (excluding metadata)
    private func hasProfileChanged(_ profile1: ProfileData?, _ profile2: ProfileData?) -> Bool {
        guard let p1 = profile1, let p2 = profile2 else {
            return profile1 != nil || profile2 != nil
        }
        
        return p1.isDarkMode != p2.isDarkMode ||
               p1.themeMode != p2.themeMode ||
               p1.language != p2.language ||
               p1.nickname != p2.nickname ||
               p1.profession != p2.profession ||
               p1.traits != p2.traits ||
               p1.additionalContext != p2.additionalContext ||
               p1.isUsingPersonalization != p2.isUsingPersonalization ||
               p1.isUsingCustomPrompt != p2.isUsingCustomPrompt ||
               p1.customSystemPrompt != p2.customSystemPrompt ||
               p1.customPromptPresets != p2.customPromptPresets ||
               p1.favoritePromptPresetIds != p2.favoritePromptPresetIds ||
               p1.reasoningEffort != p2.reasoningEffort ||
               p1.thinkingEnabled != p2.thinkingEnabled ||
               p1.webSearchEnabled != p2.webSearchEnabled ||
               p1.codeExecutionEnabled != p2.codeExecutionEnabled ||
               p1.piiCheckEnabled != p2.piiCheckEnabled ||
               p1.genUIEnabled != p2.genUIEnabled ||
               p1.chatFont != p2.chatFont ||
               p1.projectUploadPreference != p2.projectUploadPreference
    }

    func sharedSettingsDidChange() {
        // Ignore changes that originate from applying a synced/loaded profile.
        // Settings applied mid-`applyProfile` (e.g. webSearchEnabled) would
        // otherwise persist a partially-applied snapshot, since fields applied
        // later in the sequence still hold their pre-apply values. The applying
        // flow persists the full profile itself once application completes.
        guard !isApplyingProfile else { return }
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
        guard isUsingCustomPrompt else { return nil }
        return Self.normalizeSystemPromptForSending(customSystemPrompt)
    }

    static func normalizeSystemPromptForSending(_ prompt: String) -> String {
        systemPromptHasContent(prompt) ? prompt : ""
    }

    static func systemPromptHasContent(_ prompt: String) -> Bool {
        var result = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<system>") {
            result = String(result.dropFirst("<system>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.hasSuffix("</system>") {
            result = String(result.dropLast("</system>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !result.isEmpty
    }
    
    private func applyDefaultProfile() {
        isApplyingProfile = true
        isDarkMode = true
        themeMode = nil
        language = "English"
        nickname = ""
        profession = ""
        traits = []
        additionalContext = ""
        isUsingPersonalization = false
        isUsingCustomPrompt = false
        customSystemPrompt = ""
        customPromptPresets = []
        favoritePromptPresetIds = []
        isApplyingProfile = false
    }

    func resetProfile() {
        applyDefaultProfile()
        persistProfileToKeychain(createProfileData())
        markLocalProfileChanged()
        debounceCloudSync()
    }

    func clearLocalProfileForAccountRemoval() async {
        accountGeneration += 1
        syncDebounceTimer?.invalidate()
        if isFullSyncInProgress {
            await withCheckedContinuation { continuation in
                fullSyncWaiters.append(continuation)
            }
        }
        applyDefaultProfile()
        // Reset non-published profile state too, so fields and CRDT
        // clocks from the previous account never ride along into the
        // next account's first sync.
        localFieldClocks = nil
        localClockVersion = nil
        codeExecutionEnabled = nil
        piiCheckEnabled = nil
        chatFont = nil
        projectUploadPreference = nil
        keychainHelper.delete(for: keychainKey, service: keychainService)
        keychainHelper.delete(for: profileBaselineKey, service: keychainService)
        lastSyncedVersion = 0
        lastSyncedProfile = nil
        syncError = nil
        clearLocalProfileChanged()
        profileSync.clearCache()
    }
}