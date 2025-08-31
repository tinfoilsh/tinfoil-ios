//
//  SettingsView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import Clerk
import UIKit
import RevenueCat
import RevenueCatUI

// Settings Manager to handle persistence
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticFeedbackEnabled, forKey: "hapticFeedbackEnabled")
        }
    }
    
    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage")
        }
    }
    
    // Personalization settings
    @Published var isPersonalizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPersonalizationEnabled, forKey: "isPersonalizationEnabled")
        }
    }
    
    @Published var nickname: String {
        didSet {
            UserDefaults.standard.set(nickname, forKey: "userNickname")
        }
    }
    
    @Published var profession: String {
        didSet {
            UserDefaults.standard.set(profession, forKey: "userProfession")
        }
    }
    
    @Published var selectedTraits: [String] {
        didSet {
            UserDefaults.standard.set(selectedTraits, forKey: "userTraits")
        }
    }
    
    @Published var additionalContext: String {
        didSet {
            UserDefaults.standard.set(additionalContext, forKey: "userAdditionalContext")
        }
    }
    
    // Max messages setting
    @Published var maxMessages: Int {
        didSet {
            UserDefaults.standard.set(maxMessages, forKey: "maxPromptMessages")
        }
    }
    
    // Custom system prompt settings
    @Published var isUsingCustomPrompt: Bool {
        didSet {
            UserDefaults.standard.set(isUsingCustomPrompt, forKey: "isUsingCustomPrompt")
        }
    }
    
    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt")
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
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "System"
        
        // Initialize personalization settings
        self.isPersonalizationEnabled = UserDefaults.standard.object(forKey: "isPersonalizationEnabled") as? Bool ?? false
        self.nickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        self.profession = UserDefaults.standard.string(forKey: "userProfession") ?? ""
        self.additionalContext = UserDefaults.standard.string(forKey: "userAdditionalContext") ?? ""
        
        if let traitsData = UserDefaults.standard.array(forKey: "userTraits") as? [String] {
            self.selectedTraits = traitsData
        } else {
            self.selectedTraits = []
        }
        
        // Initialize max messages setting
        if let savedMaxMessages = UserDefaults.standard.object(forKey: "maxPromptMessages") as? Int {
            // Clamp the restored value to the allowed 1-50 range
            self.maxMessages = min(max(savedMaxMessages, 1), 50)
        } else {
            // Default to 15 if not set
            self.maxMessages = 15
            UserDefaults.standard.set(15, forKey: "maxPromptMessages")
        }
        
        // Initialize custom system prompt settings
        self.isUsingCustomPrompt = UserDefaults.standard.object(forKey: "isUsingCustomPrompt") as? Bool ?? false
        self.customSystemPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        
        // Ensure defaults are saved if they weren't present
        if UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "hapticFeedbackEnabled")
        }
        if UserDefaults.standard.string(forKey: "selectedLanguage") == nil {
            UserDefaults.standard.set("System", forKey: "selectedLanguage")
        }
        if UserDefaults.standard.object(forKey: "isPersonalizationEnabled") == nil {
            UserDefaults.standard.set(false, forKey: "isPersonalizationEnabled")
        }
    }
    
    // Generate user preferences XML for system prompt
    func generateUserPreferencesXML() -> String {
        guard isPersonalizationEnabled else { return "" }
        
        var xml = "<user_preferences>\n"
        
        if !nickname.isEmpty {
            xml += "  <nickname>\(nickname)</nickname>\n"
        }
        
        if !profession.isEmpty {
            xml += "  <profession>\(profession)</profession>\n"
        }
        
        if !selectedTraits.isEmpty {
            xml += "  <traits>\n"
            for trait in selectedTraits {
                xml += "    <trait>\(trait)</trait>\n"
            }
            xml += "  </traits>\n"
        }
        
        if !additionalContext.isEmpty {
            xml += "  <additional_context>\(additionalContext)</additional_context>\n"
        }
        
        xml += "</user_preferences>"
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
    @State private var navigateToCloudSync = false
    
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
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                (colorScheme == .dark ? Color.backgroundPrimary : Color(UIColor.systemGroupedBackground))
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Custom header
                    HStack {
                        Text("Settings")
                            .font(.title)
                            .fontWeight(.bold)
                        Spacer()
                        
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color(.systemGray))
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Close settings")
                    }
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .overlay(
                        Divider().opacity(0.2),
                        alignment: .bottom
                    )
                    
                    // Main content
                    Form {
                        // Account Section
                        Section {
                            if authManager.isAuthenticated {
                                // User info row
                                HStack {
                                    // Avatar
                                    Group {
                                        if let user = clerk.user, !user.imageUrl.isEmpty {
                                            AsyncImage(url: URL(string: user.imageUrl)) { image in
                                                image.resizable().aspectRatio(contentMode: .fill)
                                            } placeholder: {
                                                Image(systemName: "person.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                        } else if let userData = authManager.localUserData,
                                                  let imageUrlString = userData["imageUrl"] as? String,
                                                  !imageUrlString.isEmpty,
                                                  let url = URL(string: imageUrlString) {
                                            AsyncImage(url: url) { image in
                                                image.resizable().aspectRatio(contentMode: .fill)
                                            } placeholder: {
                                                Image(systemName: "person.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                        } else {
                                            Image(systemName: "person.circle.fill")
                                                .resizable()
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 40, height: 40)
                                    .clipShape(Circle())
                                    
                                    // User info
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
                                
                                // Edit Profile
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
                                
                                
                                // Sign Out
                                Button(action: {
                                    showSignOutConfirmation = true
                                }) {
                                    HStack {
                                        Text("Sign Out")
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                }
                                
                                // Delete Account
                                Button(action: {
                                    showDeleteConfirmation = true
                                }) {
                                    HStack {
                                        Text("Delete Account")
                                            .foregroundColor(.red)
                                        Spacer()
                                    }
                                }
                            } else {
                                // Sign in button
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
                        
                        // Preferences Section
                        Section {
                            Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
                            
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
                            
                            // Cloud Sync Settings
                            if authManager.isAuthenticated {
                                NavigationLink(
                                    destination: CloudSyncSettingsView(
                                        viewModel: chatViewModel,
                                        authManager: authManager
                                    ),
                                    isActive: $navigateToCloudSync
                                ) {
                                    Text("Cloud Sync")
                                }
                            }
                        } header: {
                            Text("Preferences")
                        }
                        
                        // Chat Settings Section
                        Section {
                            // Messages in Context
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Messages in Context")
                                        .font(.body)
                                    Text("Maximum number of recent messages sent to the model (1-50). Longer contexts increase network usage and slow down responses.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 8) {
                                    Button(action: {
                                        if settings.maxMessages > 1 {
                                            settings.maxMessages -= 1
                                        }
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(settings.maxMessages > 1 ? .accentColor : .gray)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    .disabled(settings.maxMessages <= 1)
                                    
                                    Text("\(settings.maxMessages)")
                                        .frame(minWidth: 30)
                                        .font(.system(.body, design: .monospaced))
                                    
                                    Button(action: {
                                        if settings.maxMessages < 50 {
                                            settings.maxMessages += 1
                                        }
                                    }) {
                                        Image(systemName: "plus.circle")
                                            .foregroundColor(settings.maxMessages < 50 ? .accentColor : .gray)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    .disabled(settings.maxMessages >= 50)
                                }
                            }
                            .padding(.vertical, 4)
                            
                            // Custom System Prompt
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
                                    if settings.isUsingCustomPrompt {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                            
                            // Personalization
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
                                    if settings.isPersonalizationEnabled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        } header: {
                            Text("Chat Settings")
                        }
                        
                        // Subscription Section
                        Section {
                            if authManager.hasActiveSubscription {
                                // Manage Subscription
                                let isRevenueCat = checkIfRevenueCat()
                                Button(action: {
                                    let url = isRevenueCat
                                        ? URL(string: "https://apps.apple.com/account/subscriptions")!
                                        : URL(string: "https://www.tinfoil.sh/dashboard")!
                                    UIApplication.shared.open(url)
                                }) {
                                    HStack {
                                        Text("Manage Subscription")
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.forward.square")
                                            .font(.caption2)
                                            .foregroundColor(Color(UIColor.quaternaryLabel))
                                    }
                                }
                            } else {
                                // Subscribe to Premium
                                Button(action: {
                                    // Set clerk_user_id attribute right before showing paywall
                                    if let clerkUserId = authManager.localUserData?["id"] as? String {
                                        Purchases.shared.attribution.setAttributes(["clerk_user_id": clerkUserId])
                                    }
                                    showPremiumModal = true
                                }) {
                                    HStack {
                                        Text("Subscribe to Premium")
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text("Unlock all models")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Subscription")
                        }
                        
                        // Legal Section
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
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            // Auto-navigate to Cloud Sync if requested
            if shouldOpenCloudSync {
                navigateToCloudSync = true
            }
        }
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
                .environment(Clerk.shared)
                .environmentObject(authManager)
        }
        .alert("Sign Out", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Keep Encryption Key", role: .destructive) {
                Task {
                    // Sign out but keep the encryption key
                    await authManager.signOut()
                    dismiss()
                }
            }
            Button("Delete Everything", role: .destructive) {
                Task {
                    // Clear encryption key and all local data
                    EncryptionService.shared.clearKey()
                    UserDefaults.standard.removeObject(forKey: "hasLaunchedBefore")
                    
                    // Clear all chats from local storage
                    chatViewModel.clearAllLocalChats()
                    
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Do you want to keep your encryption key and local chats for next time?\n\nIf you delete everything, you'll need to set up a new encryption key when you sign in again.")
        }
        .alert("Delete Account", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await clerk.user?.delete()
                        await authManager.signOut()
                        dismiss()
                    } catch {
                        print("Delete account error: \(error)")
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete your account? This action cannot be undone.")
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
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List(languages, id: \.self) { language in
            Button(action: {
                selectedLanguage = language
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
        }
        .navigationTitle("Default Language")
        .navigationBarTitleDisplayMode(.inline)
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
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingPrompt: String = ""
    @State private var showRestoreConfirmation = false
    
    // Get default system prompt from AppConfig
    private var defaultSystemPrompt: String {
        AppConfig.shared.systemPrompt
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Custom System Prompt", isOn: $isUsingCustomPrompt)
                    .tint(Color.green)
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
            
            if isUsingCustomPrompt {
                Section {
                    TextEditor(text: $editingPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
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
            }
        }
        .navigationTitle("Custom System Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    customSystemPrompt = editingPrompt
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            // Initialize with current custom prompt or default if empty
            editingPrompt = customSystemPrompt.isEmpty ? defaultSystemPrompt : customSystemPrompt
        }
        .alert("Restore Default", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                editingPrompt = defaultSystemPrompt
            }
        } message: {
            Text("Are you sure you want to restore the default system prompt? Your custom prompt will be replaced.")
        }
    }
}