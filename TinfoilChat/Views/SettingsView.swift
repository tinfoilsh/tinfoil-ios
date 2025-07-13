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
    
    
    private init() {
        // Initialize with stored values or defaults if not present
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "System"
        
        
        // Ensure defaults are saved if they weren't present
        if UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "hapticFeedbackEnabled")
        }
        if UserDefaults.standard.string(forKey: "selectedLanguage") == nil {
            UserDefaults.standard.set("System", forKey: "selectedLanguage")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAuthView = false
    
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
