//
//  SettingsView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI
import Clerk
import UIKit

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
    }
}

struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
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
                        HStack(spacing: 12) {
                            Image(systemName: "gear")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            Text("Settings")
                                .font(.title)
                                .fontWeight(.bold)
                        }
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
                                        Label("Edit Profile", systemImage: "person.fill")
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(Color(UIColor.quaternaryLabel))
                                    }
                                }
                                
                                // Manage Subscription
                                if authManager.hasActiveSubscription {
                                    let isRevenueCat = checkIfRevenueCat()
                                    Button(action: {
                                        let url = isRevenueCat
                                            ? URL(string: "https://apps.apple.com/account/subscriptions")!
                                            : URL(string: "https://www.tinfoil.sh/dashboard")!
                                        UIApplication.shared.open(url)
                                    }) {
                                        HStack {
                                            Label("Manage Subscription", systemImage: "creditcard")
                                                .foregroundColor(.primary)
                                            Spacer()
                                            Image(systemName: "arrow.up.forward.square")
                                                .font(.caption2)
                                                .foregroundColor(Color(UIColor.quaternaryLabel))
                                        }
                                    }
                                }
                                
                                // Sign Out
                                Button(action: {
                                    showSignOutConfirmation = true
                                }) {
                                    HStack {
                                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                }
                                
                                // Delete Account
                                Button(action: {
                                    showDeleteConfirmation = true
                                }) {
                                    HStack {
                                        Label("Delete Account", systemImage: "trash")
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
                                        Label("Sign up or Log In", systemImage: "person.badge.plus")
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
                        } header: {
                            Text("Preferences")
                        }
                        
                        // Legal Section
                        Section {
                            Button(action: {
                                UIApplication.shared.open(Constants.Legal.termsOfServiceURL)
                            }) {
                                HStack {
                                    Label("Terms of Service", systemImage: "doc.text")
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
                                    Label("Privacy Policy", systemImage: "hand.raised")
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
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
                .environmentObject(authManager)
        }
        .alert("Sign Out", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                Task {
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Are you sure you want to sign out?")
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