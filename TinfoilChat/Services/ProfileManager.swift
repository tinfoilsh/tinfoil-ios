//
//  ProfileManager.swift
//  TinfoilChat
//
//  Manages user profile settings with Keychain storage and cloud sync
//

import Foundation
import Combine
import SwiftUI

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    
    // Published properties for UI binding
    @Published var isDarkMode: Bool = true
    @Published var maxPromptMessages: Int = 10
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
    
    // Sync state
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    
    // Private properties
    private let keychainHelper = KeychainHelper.shared
    private let profileSync = ProfileSyncService.shared
    private var syncTimer: Timer?
    private var syncDebounceTimer: Timer?
    private var lastSyncedVersion: Int = 0
    private var lastSyncedProfile: ProfileData?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingProfile: Bool = false  // Flag to prevent observer loops
    
    // Keychain keys
    private let keychainKey = "userProfile"
    private let keychainService = "com.tinfoil.chat.profile"
    
    private init() {
        loadFromKeychain()
        setupChangeObservers()
        setupAutoSync()
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
        lastSyncedProfile = profile
    }
    
    /// Save profile to Keychain
    private func saveToKeychain() {
        let profile = createProfileData()
        
        guard let data = try? JSONEncoder().encode(profile) else {
            return
        }
        
        keychainHelper.save(data, for: keychainKey, service: keychainService)
        
        // For user-initiated changes, schedule a debounced cloud sync
        if !isApplyingProfile {
            if !isSyncing {
                debounceCloudSync()
            } else {
                // If a sync is running, we'll re-check after it finishes
            }
        }
    }
    
    /// Create ProfileData from current settings
    private func createProfileData() -> ProfileData {
        return ProfileData(
            isDarkMode: isDarkMode,
            maxPromptMessages: maxPromptMessages,
            language: language,
            nickname: nickname.isEmpty ? nil : nickname,
            profession: profession.isEmpty ? nil : profession,
            traits: traits.isEmpty ? nil : traits,
            additionalContext: additionalContext.isEmpty ? nil : additionalContext,
            isUsingPersonalization: isUsingPersonalization,
            isUsingCustomPrompt: isUsingCustomPrompt,
            customSystemPrompt: customSystemPrompt.isEmpty ? nil : customSystemPrompt,
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
        if let maxPromptMessages = profile.maxPromptMessages {
            self.maxPromptMessages = maxPromptMessages
        }
        if let language = profile.language {
            self.language = language
        }
        // For personalization fields, treat nil as cleared/empty to ensure cross-device erasure propagates
        self.nickname = profile.nickname ?? ""
        self.profession = profile.profession ?? ""
        self.traits = profile.traits ?? []
        self.additionalContext = profile.additionalContext ?? ""
        self.isUsingPersonalization = profile.isUsingPersonalization ?? false
        self.isUsingCustomPrompt = profile.isUsingCustomPrompt ?? false
        self.customSystemPrompt = profile.customSystemPrompt ?? ""
        if let version = profile.version {
            self.lastSyncedVersion = version
        }
        
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
        
        $maxPromptMessages
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
    }
    
    // MARK: - Cloud Sync
    
    /// Setup automatic sync timer
    private func setupAutoSync() {
        // Periodically perform full sync to push pending local changes once authenticated
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performFullSync()
            }
        }
    }
    
    /// Debounce cloud sync after local changes
    private func debounceCloudSync() {
        syncDebounceTimer?.invalidate()
        syncDebounceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.syncToCloud()
            }
        }
    }
    
    /// Sync profile from cloud
    func syncFromCloud() async {
        // Skip if not authenticated
        guard await profileSync.isAuthenticated() else {
            return
        }
        
        do {
            if let cloudProfile = try await profileSync.fetchProfile() {
                let cloudVersion = cloudProfile.version ?? 0
                
                // Simplified rule: if cloud version >= local, apply it
                if cloudVersion >= lastSyncedVersion {
                    isSyncing = true
                    applyProfile(cloudProfile)
                    
                    // Save to keychain without triggering local change observers
                    let data = try? JSONEncoder().encode(cloudProfile)
                    if let data = data {
                        keychainHelper.save(data, for: keychainKey, service: keychainService)
                    }
                    
                    lastSyncedVersion = cloudVersion
                    lastSyncedProfile = cloudProfile
                    lastSyncDate = Date()
                    syncError = nil
                    isSyncing = false
                    
                    // Cloud took precedence; local pending changes no longer relevant
                    hasPendingChanges = false
                }
            }
        } catch {
            syncError = error.localizedDescription
        }
    }
    
    /// Sync profile to cloud
    func syncToCloud() async {
        // Skip if not authenticated but keep pending flag so we can retry later
        guard await profileSync.isAuthenticated() else {
            return
        }
        
        // Avoid re-entrancy
        guard !isSyncing else {
            return
        }
        
        let profile = createProfileData()
        
        // Only push if there is a real change vs last synced baseline
        guard hasProfileChanged(profile, lastSyncedProfile) else {
            return
        }
        
        isSyncing = true
        let syncStartedAt = Date()
        
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
                lastSyncedProfile = profile
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
        
        isSyncing = false
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
                saveToKeychain()
                if let version = decryptedProfile.version {
                    lastSyncedVersion = version
                }
                lastSyncedProfile = decryptedProfile
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
               p1.maxPromptMessages != p2.maxPromptMessages ||
               p1.language != p2.language ||
               p1.nickname != p2.nickname ||
               p1.profession != p2.profession ||
               p1.traits != p2.traits ||
               p1.additionalContext != p2.additionalContext ||
               p1.isUsingPersonalization != p2.isUsingPersonalization ||
               p1.isUsingCustomPrompt != p2.isUsingCustomPrompt ||
               p1.customSystemPrompt != p2.customSystemPrompt
    }
    
    /// Generate personalization prompt for chat
    func getPersonalizationPrompt() -> String? {
        guard isUsingPersonalization else { return nil }
        
        var components: [String] = []
        
        if !nickname.isEmpty {
            components.append("The user's name is \(nickname).")
        }
        
        if !profession.isEmpty {
            components.append("They work as a \(profession).")
        }
        
        if !traits.isEmpty {
            let traitsText = traits.joined(separator: ", ")
            components.append("Their interests/traits include: \(traitsText).")
        }
        
        if !additionalContext.isEmpty {
            components.append(additionalContext)
        }
        
        if !language.isEmpty && language != "English" {
            components.append("Please respond in \(language).")
        }
        
        return components.isEmpty ? nil : components.joined(separator: " ")
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
        maxPromptMessages = 10
        language = "English"
        nickname = ""
        profession = ""
        traits = []
        additionalContext = ""
        isUsingPersonalization = false
        isUsingCustomPrompt = false
        customSystemPrompt = ""
        
        // Clear from keychain
        keychainHelper.delete(for: keychainKey, service: keychainService)
        
        // Reset sync state
        lastSyncedVersion = 0
        lastSyncedProfile = nil
        syncError = nil
        
        // Clear cloud cache
        profileSync.clearCache()
    }
}