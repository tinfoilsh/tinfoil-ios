//
//  SettingsView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI

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
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAuthView = false
    @State private var showSaveConfirmation = false
    
    // Local state for form fields
    @State private var localNickname = ""
    @State private var localProfession = ""
    @State private var localTraits: [String] = []
    @State private var localAdditionalContext = ""
    
    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
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
        VStack(spacing: 0) {
            // Custom header based on VerifierViewController
            panelHeader
            
            // Content
            NavigationView {
                List {
                    Section(header: Text("Preferences")) {
                        Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
                        
                        Picker("Default Language", selection: $settings.selectedLanguage) {
                            ForEach(languages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    
                    Section(header: Text("Personalization")) {
                        Toggle("Enable Personalization", isOn: $settings.isPersonalizationEnabled)
                            .tint(.blue)
                        
                        if settings.isPersonalizationEnabled {
                            personalizationContent
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                                .buttonStyle(PlainButtonStyle())
                        }
                    }
                    
                    Section(header: Text("Legal")) {
                        Link(destination: Constants.Legal.termsOfServiceURL) {
                            HStack {
                                Text("Terms of Service")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        Link(destination: Constants.Legal.privacyPolicyURL) {
                            HStack {
                                Text("Privacy Policy")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                .navigationBarHidden(true)
                .listStyle(InsetGroupedListStyle())
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .background(Color(UIColor.systemGroupedBackground))
        .accentColor(.primary)
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
        }
        .overlay(
            saveConfirmationOverlay,
            alignment: .top
        )
        .onAppear {
            localNickname = settings.nickname
            localProfession = settings.profession
            localTraits = settings.selectedTraits
            localAdditionalContext = settings.additionalContext
        }
    }
    
    // Personalization content view
    private var personalizationContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("How should Tin call you?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Nickname", text: $localNickname)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: localNickname) { newValue in
                        settings.nickname = newValue
                    }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you do?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Profession", text: $localProfession)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: localProfession) { newValue in
                        settings.profession = newValue
                    }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversational traits")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TraitSelectionView(
                    availableTraits: settings.availableTraits,
                    selectedTraits: $localTraits
                )
                .onChange(of: localTraits) { newValue in
                    settings.selectedTraits = newValue
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Additional context")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Anything else Tin should know about you?", text: $localAdditionalContext, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(3...6)
                    .onChange(of: localAdditionalContext) { newValue in
                        settings.additionalContext = newValue
                    }
            }
            
            VStack(spacing: 0) {
                // Non-interactive spacer
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 16)
                
                // Button container with explicit boundaries
                HStack(spacing: 16) {
                    // Reset button
                    Button(action: {
                        settings.resetPersonalization()
                        localNickname = ""
                        localProfession = ""
                        localTraits = []
                        localAdditionalContext = ""
                    }) {
                        Text("Reset")
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    
                    // Save button
                    Button(action: {
                        // Dismiss keyboard first
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        
                        // Show confirmation after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showSaveConfirmation = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                showSaveConfirmation = false
                            }
                        }
                    }) {
                        Text("Save")
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .background(Color.clear)
                .contentShape(Rectangle())
            }
        }
    }
    
    // Save confirmation overlay
    private var saveConfirmationOverlay: some View {
        Group {
            if showSaveConfirmation {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Settings saved")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                )
                .padding(.top, 80)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showSaveConfirmation)
            }
        }
    }
    
    // Panel header matching the style from VerifierViewController
    private var panelHeader: some View {
        HStack {
            Text("Settings")
                .font(.title)
                .fontWeight(.bold)
            Spacer()
            
            // Dismiss button with X icon
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(.systemGray))
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Close settings screen")
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .overlay(
            Divider()
                .opacity(0.2)
            , alignment: .bottom
        )
    }
}

// Trait selection view for personality traits
struct TraitSelectionView: View {
    let availableTraits: [String]
    @Binding var selectedTraits: [String]
    
    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 8)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(availableTraits, id: \.self) { trait in
                Button(action: {
                    toggleTrait(trait)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: selectedTraits.contains(trait) ? "checkmark" : "plus")
                            .font(.footnote)
                        Text(trait)
                            .font(.footnote)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(selectedTraits.contains(trait) ? Color.blue : Color.gray.opacity(0.2))
                    )
                    .foregroundColor(selectedTraits.contains(trait) ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func toggleTrait(_ trait: String) {
        if selectedTraits.contains(trait) {
            selectedTraits.removeAll { $0 == trait }
        } else {
            selectedTraits.append(trait)
        }
    }
}
