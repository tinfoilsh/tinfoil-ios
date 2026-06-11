//
//  SettingsView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import ClerkKit
import UIKit
import RevenueCat
import RevenueCatUI

// Settings Manager to handle persistence
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticFeedbackEnabled, forKey: Constants.StorageKeys.Settings.hapticFeedbackEnabled)
        }
    }
    
    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: Constants.StorageKeys.Settings.selectedLanguage)
        }
    }
    
    // Personalization settings
    @Published var isPersonalizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPersonalizationEnabled, forKey: Constants.StorageKeys.UserPrefs.personalizationEnabled)
        }
    }
    
    @Published var nickname: String {
        didSet {
            UserDefaults.standard.set(nickname, forKey: Constants.StorageKeys.UserPrefs.nickname)
        }
    }
    
    @Published var profession: String {
        didSet {
            UserDefaults.standard.set(profession, forKey: Constants.StorageKeys.UserPrefs.profession)
        }
    }
    
    @Published var selectedTraits: [String] {
        didSet {
            UserDefaults.standard.set(selectedTraits, forKey: Constants.StorageKeys.UserPrefs.traits)
        }
    }
    
    @Published var additionalContext: String {
        didSet {
            UserDefaults.standard.set(additionalContext, forKey: Constants.StorageKeys.UserPrefs.additionalContext)
        }
    }
    
    // Custom system prompt settings
    @Published var isUsingCustomPrompt: Bool {
        didSet {
            UserDefaults.standard.set(isUsingCustomPrompt, forKey: Constants.StorageKeys.UserPrefs.customPromptEnabled)
        }
    }
    
    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: Constants.StorageKeys.UserPrefs.customSystemPrompt)
        }
    }

    // Web search toggle
    @Published var webSearchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(webSearchEnabled, forKey: Constants.StorageKeys.Settings.webSearchEnabled)
        }
    }

    // Cloud sync toggle
    @Published var isCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCloudSyncEnabled, forKey: Constants.StorageKeys.Settings.cloudSyncEnabled)
        }
    }

    // Local-only mode toggle (only relevant when cloud sync is enabled)
    @Published var isLocalOnlyModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLocalOnlyModeEnabled, forKey: Constants.StorageKeys.Settings.localOnlyModeEnabled)
        }
    }

    // Available personality traits
    let availableTraits = [
        "witty", "encouraging", "formal", "casual", "analytical", "creative",
        "direct", "patient", "enthusiastic", "thoughtful", "forward thinking",
        "traditional", "skeptical", "optimistic"
    ]
    
    private init() {
        // Initialize with stored values or defaults if not present
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.hapticFeedbackEnabled) as? Bool ?? true
        self.selectedLanguage = UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.selectedLanguage) ?? "System"
        
        // Initialize personalization settings
        self.isPersonalizationEnabled = UserDefaults.standard.object(forKey: Constants.StorageKeys.UserPrefs.personalizationEnabled) as? Bool ?? false
        self.nickname = UserDefaults.standard.string(forKey: Constants.StorageKeys.UserPrefs.nickname) ?? ""
        self.profession = UserDefaults.standard.string(forKey: Constants.StorageKeys.UserPrefs.profession) ?? ""
        self.additionalContext = UserDefaults.standard.string(forKey: Constants.StorageKeys.UserPrefs.additionalContext) ?? ""
        
        if let traitsData = UserDefaults.standard.array(forKey: Constants.StorageKeys.UserPrefs.traits) as? [String] {
            self.selectedTraits = traitsData
        } else {
            self.selectedTraits = []
        }
        
        // Initialize custom system prompt settings
        self.isUsingCustomPrompt = UserDefaults.standard.object(forKey: Constants.StorageKeys.UserPrefs.customPromptEnabled) as? Bool ?? false
        self.customSystemPrompt = UserDefaults.standard.string(forKey: Constants.StorageKeys.UserPrefs.customSystemPrompt) ?? ""

        // Initialize web search setting
        self.webSearchEnabled = UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.webSearchEnabled) as? Bool ?? true

        // Initialize cloud sync setting
        // If no explicit value has been stored, auto-enable for existing users who already have an encryption key
        if let storedValue = UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.cloudSyncEnabled) as? Bool {
            self.isCloudSyncEnabled = storedValue
        } else if EncryptionService.shared.hasEncryptionKey() {
            self.isCloudSyncEnabled = true
            UserDefaults.standard.set(true, forKey: Constants.StorageKeys.Settings.cloudSyncEnabled)
        } else {
            self.isCloudSyncEnabled = false
        }

        // Initialize local-only mode setting (defaults to false)
        self.isLocalOnlyModeEnabled = UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.localOnlyModeEnabled) as? Bool ?? false

        // Ensure defaults are saved if they weren't present
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.hapticFeedbackEnabled) == nil {
            UserDefaults.standard.set(true, forKey: Constants.StorageKeys.Settings.hapticFeedbackEnabled)
        }
        if UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.selectedLanguage) == nil {
            UserDefaults.standard.set("System", forKey: Constants.StorageKeys.Settings.selectedLanguage)
        }
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.UserPrefs.personalizationEnabled) == nil {
            UserDefaults.standard.set(false, forKey: Constants.StorageKeys.UserPrefs.personalizationEnabled)
        }
    }

    /// Clear all settings (call on logout with data deletion)
    func clearAllSettings() {
        // Clear all user data from UserDefaults
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Settings.hapticFeedbackEnabled)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Settings.selectedLanguage)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.personalizationEnabled)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.nickname)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.profession)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.traits)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.additionalContext)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.customPromptEnabled)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.UserPrefs.customSystemPrompt)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Settings.webSearchEnabled)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Settings.cloudSyncEnabled)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Settings.localOnlyModeEnabled)

        // Reset in-memory state to defaults
        hapticFeedbackEnabled = true
        selectedLanguage = "System"
        isPersonalizationEnabled = false
        nickname = ""
        profession = ""
        selectedTraits = []
        additionalContext = ""
        isUsingCustomPrompt = false
        customSystemPrompt = ""
        webSearchEnabled = true
        isCloudSyncEnabled = false
        isLocalOnlyModeEnabled = false
    }

    // Generate user preferences XML for system prompt.
    // Treats `isPersonalizationEnabled` as a soft preference: when any field is
    // populated we still inject it so the model has the user's context. This
    // matches `ProfileManager.getPersonalizationPrompt()`.
    func generateUserPreferencesXML() -> String {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProfession = profession.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyTraits = selectedTraits.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let trimmedContext = additionalContext.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasAnyField = !trimmedNickname.isEmpty
            || !trimmedProfession.isEmpty
            || !nonEmptyTraits.isEmpty
            || !trimmedContext.isEmpty

        guard hasAnyField else { return "" }

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
    
    // Reset all personalization settings
    func resetPersonalization() {
        nickname = ""
        profession = ""
        selectedTraits = []
        additionalContext = ""
        isPersonalizationEnabled = false
    }
}

struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(Clerk.self) private var clerk
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared
    @ObservedObject private var passkeyManager = PasskeyManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAuthView = false
    @State private var showDeleteConfirmation = false
    @State private var showProfileEditor = false
    @State private var editingFirstName = ""
    @State private var editingLastName = ""
    @State private var isUpdatingProfile = false
    @State private var profileUpdateError: String? = nil
    @State private var showLanguagePicker = false
    @State private var showSignOutConfirmation = false
    @State private var showPremiumModal = false
    @State private var accountDeletionError: String? = nil
    @State private var showDeleteAllChatsConfirm = false
    @State private var deleteAllChatsConfirmText = ""
    @State private var isDeletingAllChats = false
    @State private var deleteAllChatsResult: String? = nil

    /// Typed confirmation phrase gating the bulk chat deletion, matching the
    /// webapp's safeguard for the same feature.
    private static let deleteAllChatsConfirmPhrase = "delete all chats"

    var shouldOpenCloudSync: Bool = false
    
    // Complete list of languages based on ISO 639-1
    var languages: [String] {
        ["System"] + [
            "Afrikaans", "Albanian", "Arabic", "Armenian", "Azerbaijani",
            "Basque", "Belarusian", "Bengali", "Bosnian", "Bulgarian",
            "Catalan", "Chinese (Simplified)", "Chinese (Traditional)", "Croatian", "Czech",
            "Danish", "Dutch", "English", "Estonian", "Filipino",
            "Finnish", "French", "Galician", "Georgian", "German",
            "Greek", "Gujarati", "Haitian Creole", "Hebrew", "Hindi",
            "Hungarian", "Icelandic", "Indonesian", "Irish", "Italian",
            "Japanese", "Kannada", "Kazakh", "Korean", "Latin",
            "Latvian", "Lithuanian", "Macedonian", "Malay", "Malayalam",
            "Maltese", "Marathi", "Mongolian", "Norwegian", "Persian",
            "Polish", "Portuguese", "Romanian", "Russian", "Serbian",
            "Slovak", "Slovenian", "Spanish", "Swahili", "Swedish",
            "Tamil", "Telugu", "Thai", "Turkish", "Ukrainian",
            "Urdu", "Uzbek", "Vietnamese", "Welsh", "Yiddish"
        ].sorted()
    }
    
    @ViewBuilder
    private var userAvatar: some View {
        if let user = clerk.user, user.hasImage, !user.imageUrl.isEmpty {
            AsyncImage(url: URL(string: user.imageUrl)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                PixelAvatarView(name: user.id, size: 40)
            }
        } else if let userData = authManager.localUserData,
                  (userData["hasImage"] as? Bool) == true,
                  let imageUrlString = userData["imageUrl"] as? String,
                  !imageUrlString.isEmpty,
                  let url = URL(string: imageUrlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                PixelAvatarView(name: (userData["id"] as? String) ?? "user", size: 40)
            }
        } else {
            PixelAvatarView(name: clerk.user?.id ?? (authManager.localUserData?["id"] as? String) ?? "user", size: 40)
        }
    }
    
    /// Shared destructive cleanup used by both "Delete Everything" and "Delete Account".
    private func performFullDataCleanup() async {
        EncryptionService.shared.clearKey()
        await DeviceEncryptionService.shared.clearKey()
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Settings.hasLaunchedBefore)
        await chatViewModel.clearAllChatsFromDevice()
        settings.clearAllSettings()
        ProfileManager.shared.clearProfile()
    }

    private var accountSection: some View {
        Section {
            if authManager.isAuthenticated {
                NavigationLink(destination: manageAccountPage) {
                    accountSummaryRow
                }
            } else {
                Button(action: {
                    showAuthView = true
                }) {
                    HStack {
                        Text("Sign up or Log In")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
        } header: {
            Text("Account")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var accountSummaryRow: some View {
        HStack {
            userAvatar
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                if let user = clerk.user {
                    Text("\(user.firstName ?? "") \(user.lastName ?? "")")
                        .font(.body)
                        .foregroundColor(.primary)
                    if let email = user.emailAddresses.first?.emailAddress {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let userData = authManager.localUserData {
                    Text((userData["name"] as? String) ?? "User")
                        .font(.body)
                        .foregroundColor(.primary)
                    if let email = userData["email"] as? String {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var manageAccountPage: some View {
        Form {
            Section {
                accountSummaryRow
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section {
                Button(action: {
                    if let user = clerk.user {
                        editingFirstName = user.firstName ?? ""
                        editingLastName = user.lastName ?? ""
                        showProfileEditor = true
                    }
                }) {
                    HStack {
                        Text("Edit Profile")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Color(UIColor.quaternaryLabel))
                    }
                }

                Button(action: {
                    showSignOutConfirmation = true
                }) {
                    HStack {
                        Text("Sign Out")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section {
                Button(action: {
                    showDeleteConfirmation = true
                }) {
                    HStack {
                        Text("Delete Account")
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Manage Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign Out", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out") {
                Task {
                    await performFullDataCleanup()
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            if settings.isLocalOnlyModeEnabled {
                Text(passkeyManager.passkeyActive
                    ? "All local data will be cleared. You can recover your chats by signing back in.\n\n⚠️ Your local chats will be deleted forever."
                    : "All local data will be cleared. You will need your encryption key to recover your chats.\n\n⚠️ Your local chats will be deleted forever.")
            } else {
                Text(passkeyManager.passkeyActive
                    ? "All local data will be cleared. You can recover your chats by signing back in."
                    : "All local data will be cleared. You will need your encryption key to recover your chats.")
            }
        }
        .alert("Delete Account", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await clerk.user?.delete()
                        await performFullDataCleanup()
                        await authManager.signOut()
                        dismiss()
                    } catch {
                        accountDeletionError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete your account? This action cannot be undone.")
        }
        .alert("Account Deletion Failed", isPresented: Binding(
            get: { accountDeletionError != nil },
            set: { if !$0 { accountDeletionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(accountDeletionError ?? "")
        }
        .sheet(isPresented: $showProfileEditor) {
            ProfileEditorView(
                firstName: $editingFirstName,
                lastName: $editingLastName,
                isUpdating: $isUpdatingProfile,
                errorMessage: $profileUpdateError,
                onSave: {
                    Task {
                        await updateProfile()
                    }
                },
                onCancel: {
                    showProfileEditor = false
                }
            )
            .environment(clerk)
        }
    }

    private var preferencesSection: some View {
        Section {
            Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
                .tint(Color.accentPrimary)
        } header: {
            Text("Preferences")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var chatSettingsSection: some View {
        Section {
            NavigationLink(destination: LanguagePickerView(
                selectedLanguage: $settings.selectedLanguage,
                languages: languages
            )) {
                HStack {
                    Text("Default Language")
                    Spacer()
                    Text(settings.selectedLanguage)
                        .foregroundColor(.secondary)
                }
            }

            if authManager.isAuthenticated {
                NavigationLink {
                    CloudSyncSettingsView(
                        viewModel: chatViewModel,
                        authManager: authManager
                    )
                } label: {
                    HStack {
                        Text("Cloud Sync")
                        Spacer()
                        Text(settings.isCloudSyncEnabled ? "On" : "Off")
                            .foregroundColor(.secondary)
                    }
                }

            }

            NavigationLink(destination: CustomSystemPromptView(
                isUsingCustomPrompt: $settings.isUsingCustomPrompt,
                customSystemPrompt: $settings.customSystemPrompt
            )) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom System Prompt")
                            .font(.body)
                        Text("Override the default system prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if profileManager.isUsingCustomPrompt {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .accessibilityLabel("Enabled")
                    }
                }
            }

            NavigationLink(destination: PersonalizationView()) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personalization")
                            .font(.body)
                        Text("Customize how the AI responds to you")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if profileManager.isUsingPersonalization || settings.isPersonalizationEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .accessibilityLabel("Enabled")
                    }
                }
            }
        } header: {
            Text("Chat Settings")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var dataSection: some View {
        Section {
            Button(action: {
                showDeleteAllChatsConfirm = true
            }) {
                HStack {
                    Text("Delete All Chats")
                        .foregroundColor(.red)
                    Spacer()
                    if isDeletingAllChats {
                        ProgressView()
                    }
                }
            }
            .disabled(isDeletingAllChats)
        } header: {
            Text("Data")
        } footer: {
            Text(authManager.isAuthenticated
                 ? "Permanently delete every chat from this device and your encrypted cloud backup. This cannot be undone."
                 : "Permanently delete every chat from this device. This cannot be undone.")
                .font(.caption)
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
        .alert("Delete All Chats", isPresented: $showDeleteAllChatsConfirm) {
            TextField(Self.deleteAllChatsConfirmPhrase, text: $deleteAllChatsConfirmText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {
                deleteAllChatsConfirmText = ""
            }
            Button("Delete", role: .destructive) {
                confirmDeleteAllChats()
            }
        } message: {
            Text("This permanently deletes every chat and cannot be undone. Type \"\(Self.deleteAllChatsConfirmPhrase)\" to confirm.")
        }
        .alert("Delete All Chats", isPresented: Binding(
            get: { deleteAllChatsResult != nil },
            set: { if !$0 { deleteAllChatsResult = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteAllChatsResult ?? "")
        }
    }

    /// Re-checks the typed phrase before deleting, mirroring the webapp's
    /// defense-in-depth gate on the same action.
    private func confirmDeleteAllChats() {
        let typed = deleteAllChatsConfirmText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        deleteAllChatsConfirmText = ""
        guard typed == Self.deleteAllChatsConfirmPhrase else {
            deleteAllChatsResult = "Deletion cancelled: the confirmation phrase didn't match."
            return
        }
        isDeletingAllChats = true
        Task {
            do {
                try await chatViewModel.deleteAllChats()
                deleteAllChatsResult = "All chats have been deleted."
            } catch {
                deleteAllChatsResult = "Failed to delete all chats. Please try again."
            }
            isDeletingAllChats = false
        }
    }

    private var subscriptionSection: some View {
        Section {
            if authManager.hasActiveSubscription {
                Button(action: {
                    let isRevenueCat = checkIfRevenueCat()
                    let url = isRevenueCat
                        ? URL(string: "https://apps.apple.com/account/subscriptions")!
                        : URL(string: "https://dash.tinfoil.sh")!
                    UIApplication.shared.open(url)
                }) {
                    HStack {
                        Text("Manage Subscription")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.footnote)
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                }
            } else {
                Button(action: {
                    guard authManager.isAuthenticated else {
                        showAuthView = true
                        return
                    }
                    if let clerkUserId = authManager.localUserData?["id"] as? String {
                        Purchases.shared.attribution.setAttributes(["clerk_user_id": clerkUserId])
                    }
                    showPremiumModal = true
                }) {
                    HStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "sparkles")
                            .font(.subheadline.weight(.semibold))
                        Text("Subscribe to Premium")
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.tinfoilAccentDark)
            }
        } header: {
            Text("Subscription")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var contactSection: some View {
        Section {
            Link(destination: URL(string: "mailto:contact@tinfoil.sh")!) {
                HStack {
                    Text("Send Email")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("contact@tinfoil.sh")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
            }
        } header: {
            Text("Contact Us")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var legalSection: some View {
        Section {
            Button(action: {
                UIApplication.shared.open(Constants.Legal.termsOfServiceURL)
            }) {
                HStack {
                    Text("Terms of Service")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .font(.footnote)
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }

            Button(action: {
                UIApplication.shared.open(Constants.Legal.privacyPolicyURL)
            }) {
                HStack {
                    Text("Privacy Policy")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .font(.footnote)
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
        } header: {
            Text("Legal")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                subscriptionSection
                chatSettingsSection
                preferencesSection
                dataSection
                contactSection
                legalSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.settingsBackground(for: colorScheme))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .onAppear {
            // Reset navigation bar to use system colors for settings screens
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            
            // Auto-navigate to Cloud Sync if requested
            if shouldOpenCloudSync {
            }
            
            // Sync ProfileManager settings
            Task {
                // Trigger sync from cloud
                await ProfileManager.shared.syncFromCloud()
                
                // Update settings from ProfileManager
                await MainActor.run {
                    let profileManager = ProfileManager.shared
                    
                    // Update language if different
                    if !profileManager.language.isEmpty && profileManager.language != "System" {
                        settings.selectedLanguage = profileManager.language
                    }
                    
                    // Update custom prompt settings from single source of truth (ProfileManager)
                    settings.isUsingCustomPrompt = profileManager.isUsingCustomPrompt
                    settings.customSystemPrompt = profileManager.customSystemPrompt
                }
            }
        }
        .onDisappear {
            // Restore dark navigation bar for main chat view
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Color.backgroundPrimary)
            appearance.shadowColor = .clear
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
        // Keep UI settings in sync with ProfileManager when remote changes arrive
        .onReceive(ProfileManager.shared.$language) { newValue in
            if !newValue.isEmpty && settings.selectedLanguage != newValue {
                settings.selectedLanguage = newValue
            }
        }
        .onReceive(ProfileManager.shared.$isUsingCustomPrompt) { newValue in
            if settings.isUsingCustomPrompt != newValue {
                settings.isUsingCustomPrompt = newValue
            }
        }
        .onReceive(ProfileManager.shared.$customSystemPrompt) { newValue in
            if settings.customSystemPrompt != newValue {
                settings.customSystemPrompt = newValue
            }
        }
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
                .environment(Clerk.shared)
                .environmentObject(authManager)
        }
        .sheet(isPresented: $showPremiumModal) {
            PaywallView(displayCloseButton: true)
                .onPurchaseCompleted { _ in
                    showPremiumModal = false
                    // The subscription status will update automatically via webhook
                }
                .onDisappear {
                    // Check subscription status when paywall is dismissed
                    Task {
                        await authManager.fetchSubscriptionStatus()
                    }
                }
        }

    }
    
    private func checkIfRevenueCat() -> Bool {
        if let metadata = clerk.user?.publicMetadata,
           let source = metadata["chat_subscription_source"] {
            let sourceString = "\(source)".replacingOccurrences(of: "\"", with: "")
            return sourceString == "ios_revenuecat"
        }
        return false
    }
    
    private func updateProfile() async {
        isUpdatingProfile = true
        profileUpdateError = nil
        
        do {
            var updateParams = User.UpdateParams()
            updateParams.firstName = editingFirstName
            updateParams.lastName = editingLastName
            try await clerk.user?.update(updateParams)
            
            await authManager.initializeAuthState()
            showProfileEditor = false
        } catch {
            profileUpdateError = error.localizedDescription
        }
        
        isUpdatingProfile = false
    }
}

// Language Picker View
struct LanguagePickerView: View {
    @Binding var selectedLanguage: String
    let languages: [String]
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List(languages, id: \.self) { language in
            Button(action: {
                selectedLanguage = language
                profileManager.language = language
                dismiss()
            }) {
                HStack {
                    Text(language)
                    Spacer()
                    if selectedLanguage == language {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .foregroundColor(.primary)
            .accessibilityAddTraits(selectedLanguage == language ? .isSelected : [])
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Default Language")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()

            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance

            // Load from ProfileManager if available
            if !profileManager.language.isEmpty && profileManager.language != "English" {
                selectedLanguage = profileManager.language
            }
            
            // Trigger sync to get latest from cloud
            Task {
                await profileManager.syncFromCloud()
                await MainActor.run {
                    if !profileManager.language.isEmpty && profileManager.language != "English" {
                        selectedLanguage = profileManager.language
                    }
                }
            }
        }
        .onDisappear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Color.backgroundPrimary)
            appearance.shadowColor = .clear

            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// Profile Editor View
struct ProfileEditorView: View {
    @Binding var firstName: String
    @Binding var lastName: String
    @Binding var isUpdating: Bool
    @Binding var errorMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    
    enum Field {
        case firstName, lastName
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First Name", text: $firstName)
                        .textContentType(.givenName)
                        .focused($focusedField, equals: .firstName)
                        .disabled(isUpdating)
                    
                    TextField("Last Name", text: $lastName)
                        .textContentType(.familyName)
                        .focused($focusedField, equals: .lastName)
                        .disabled(isUpdating)
                } header: {
                    Text("Name")
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    .listRowBackground(Color.cardSurface(for: colorScheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.settingsBackground(for: colorScheme))
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(isUpdating)
                }
            }
            .overlay {
                if isUpdating {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.3))
                }
            }
        }
        .onAppear {
            focusedField = .firstName
        }
    }
}

// Custom System Prompt View
struct CustomSystemPromptView: View {
    @Binding var isUsingCustomPrompt: Bool
    @Binding var customSystemPrompt: String
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingPrompt: String = ""
    @State private var showRestoreConfirmation = false
    
    private var defaultSystemPrompt: String {
        AppConfig.shared.systemPrompt
    }
    
    private func stripSystemTags(_ prompt: String) -> String {
        var result = prompt
        if result.hasPrefix("<system>") {
            result = String(result.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.hasSuffix("</system>") {
            result = String(result.dropLast(9)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Custom System Prompt", isOn: $isUsingCustomPrompt)
                    .tint(Color.green)
                    .onChange(of: isUsingCustomPrompt) { _, newValue in
                        profileManager.isUsingCustomPrompt = newValue
                        if newValue {
                            var currentEditor = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            if currentEditor.isEmpty {
                                currentEditor = stripSystemTags(defaultSystemPrompt)
                                editingPrompt = currentEditor
                            }
                            if profileManager.customSystemPrompt.isEmpty {
                                var promptToSave = currentEditor
                                if !promptToSave.hasPrefix("<system>") { promptToSave = "<system>\n\(promptToSave)" }
                                if !promptToSave.hasSuffix("</system>") { promptToSave += "\n</system>" }
                                profileManager.customSystemPrompt = promptToSave
                            }
                        }
                    }
            } header: {
                Text("Status")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When enabled, your custom prompt will override the default system prompt")
                        .font(.caption)
                    
                    if isUsingCustomPrompt {
                        Text("Tip: Use placeholders like {USER_PREFERENCES}, {LANGUAGE}, {CURRENT_DATETIME}, and {TIMEZONE} to tell the model about your preferences, timezone, and the current time and date.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
            
            if isUsingCustomPrompt {
                Section {
                    TextEditor(text: $editingPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                        .accessibilityLabel("Custom prompt")
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Prompt")
                        HStack {
                            Button(action: {
                                showRestoreConfirmation = true
                            }) {
                                Text("Restore default prompt")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            Spacer()
                            Button(action: {
                                editingPrompt = ""
                            }) {
                                Text("Clear")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Custom System Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    var promptToSave = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !promptToSave.isEmpty {
                        if !promptToSave.hasPrefix("<system>") {
                            promptToSave = "<system>\n\(promptToSave)"
                        }
                        if !promptToSave.hasSuffix("</system>") {
                            promptToSave = "\(promptToSave)\n</system>"
                        }
                    }
                    
                    profileManager.customSystemPrompt = promptToSave
                    profileManager.isUsingCustomPrompt = isUsingCustomPrompt
                    customSystemPrompt = promptToSave
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            
            if !profileManager.customSystemPrompt.isEmpty {
                editingPrompt = stripSystemTags(profileManager.customSystemPrompt)
                isUsingCustomPrompt = profileManager.isUsingCustomPrompt
            } else if !customSystemPrompt.isEmpty {
                editingPrompt = stripSystemTags(customSystemPrompt)
            } else {
                editingPrompt = stripSystemTags(defaultSystemPrompt)
            }
            
            Task {
                await profileManager.syncFromCloud()
                await MainActor.run {
                    if !profileManager.customSystemPrompt.isEmpty {
                        editingPrompt = stripSystemTags(profileManager.customSystemPrompt)
                        isUsingCustomPrompt = profileManager.isUsingCustomPrompt
                    }
                }
            }
        }
        .onDisappear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Color.backgroundPrimary)
            appearance.shadowColor = .clear
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
        .alert("Restore Default", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                var strippedDefault = defaultSystemPrompt
                if strippedDefault.hasPrefix("<system>") {
                    strippedDefault = String(strippedDefault.dropFirst(8))
                    strippedDefault = strippedDefault.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if strippedDefault.hasSuffix("</system>") {
                    strippedDefault = String(strippedDefault.dropLast(9))
                    strippedDefault = strippedDefault.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                editingPrompt = strippedDefault
            }
        } message: {
            Text("Are you sure you want to restore the default system prompt? Your custom prompt will be replaced.")
        }
    }
}
