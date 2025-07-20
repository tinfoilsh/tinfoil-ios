//
//  SettingsView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI
import Clerk

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
                    // Account Section
                    Section {
                        if authManager.isAuthenticated {
                            // User info row
                            HStack {
                                // Display user info if available
                                if let user = clerk.user {
                                    if !user.imageUrl.isEmpty {
                                        AsyncImage(url: URL(string: user.imageUrl)) { image in
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Image(systemName: "person.circle.fill")
                                        }
                                        .frame(width: 40, height: 40)
                                        .clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.circle.fill")
                                            .resizable()
                                            .frame(width: 40, height: 40)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(user.firstName ?? "") \(user.lastName ?? "")")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if let email = user.emailAddresses.first?.emailAddress {
                                            Text(email)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                // If user is not in clerk but in local storage
                                else if let userData = authManager.localUserData {
                                    if let imageUrlString = userData["imageUrl"] as? String, 
                                       !imageUrlString.isEmpty,
                                       let url = URL(string: imageUrlString) {
                                        AsyncImage(url: url) { image in
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Image(systemName: "person.circle.fill")
                                        }
                                        .frame(width: 40, height: 40)
                                        .clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.circle.fill")
                                            .resizable()
                                            .frame(width: 40, height: 40)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((userData["name"] as? String) ?? "User")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if let email = userData["email"] as? String {
                                            Text(email)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .resizable()
                                        .frame(width: 40, height: 40)
                                        .foregroundColor(.secondary)
                                    
                                    Text("Account")
                                        .foregroundColor(.primary)
                                }
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            
                            // Edit Profile button
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
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            // Manage Subscription link - conditionally show based on subscription source
                            if authManager.hasActiveSubscription {
                                // Get subscription source with more robust checking
                                let isRevenueCat: Bool = {
                                    if let metadata = clerk.user?.publicMetadata,
                                       let source = metadata["chat_subscription_source"] {
                                        let sourceString = "\(source)".replacingOccurrences(of: "\"", with: "")
                                        return sourceString == "ios_revenuecat"
                                    }
                                    return false
                                }()
                                
                                
                                if isRevenueCat {
                                    // In-app purchase - link to iOS subscription settings
                                    Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                                        HStack {
                                            Text("Manage Subscription")
                                            Spacer()
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.caption)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                } else {
                                    // Web subscription - link to Tinfoil dashboard
                                    Link(destination: URL(string: "https://www.tinfoil.sh/dashboard")!) {
                                        HStack {
                                            Text("Manage Subscription")
                                            Spacer()
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.caption)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                            // Sign Out button
                            Button(action: {
                                Task {
                                    await authManager.signOut()
                                    dismiss()
                                }
                            }) {
                                HStack {
                                    Text("Sign Out")
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            // Delete Account button
                            Button(action: {
                                showDeleteConfirmation = true
                            }) {
                                HStack {
                                    Text("Delete Account")
                                        .foregroundColor(.red)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                        } else {
                            // Sign in button for non-authenticated users
                            Button(action: {
                                showAuthView = true
                            }) {
                                HStack {
                                    Image(systemName: "person.badge.plus")
                                        .foregroundColor(.primary)
                                    Text("Sign up or Log In")
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    } header: {
                        Text("Account")
                    }
                    
                    Section {
                        Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
                            .tint(Color.accentPrimary)
                        
                        Picker("Default Language", selection: $settings.selectedLanguage) {
                            ForEach(languages, id: \.self) { language in
                                Text(language).tag(language)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } header: {
                        Text("Preferences")
                    }
                    
                    Section {
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
                    } header: {
                        Text("Legal")
                    }
                }
                .navigationBarHidden(true)
                .listStyle(InsetGroupedListStyle())
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { _ in
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                )
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .background(Color(UIColor.systemGroupedBackground))
        .accentColor(Color.accentPrimary)
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
                .environmentObject(authManager)
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
    
    // Panel header matching the style from VerifierViewController
    private var panelHeader: some View {
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
    
    // Update user profile
    private func updateProfile() async {
        isUpdatingProfile = true
        profileUpdateError = nil
        
        do {
            // Update user profile
            var updateParams = User.UpdateParams()
            updateParams.firstName = editingFirstName
            updateParams.lastName = editingLastName
            try await clerk.user?.update(updateParams)
            
            // Refresh auth state
            await authManager.initializeAuthState()
            
            showProfileEditor = false
        } catch {
            profileUpdateError = error.localizedDescription
        }
        
        isUpdatingProfile = false
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
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .foregroundColor(.blue)
                
                Spacer()
                
                Text("Edit Profile")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Save") {
                    onSave()
                }
                .foregroundColor(.blue)
                .fontWeight(.semibold)
                .disabled(isUpdating)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .overlay(
                Divider()
                    .opacity(0.2)
                , alignment: .bottom
            )
            
            // Form
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
            
            if isUpdating {
                ProgressView()
                    .padding()
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            focusedField = .firstName
        }
    }
}

// Trait selection view for personality traits
struct TraitSelectionView: View {
    let availableTraits: [String]
    @Binding var selectedTraits: [String]
    
    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(availableTraits, id: \.self) { trait in
                Button(action: {
                    toggleTrait(trait)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: selectedTraits.contains(trait) ? "checkmark" : "plus")
                            .font(.subheadline)
                        Text(trait)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(selectedTraits.contains(trait) ? Color.accentPrimary : Color.gray.opacity(0.2))
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

// Custom FlowLayout for flexible tag arrangement
struct FlowLayout: Layout {
    let spacing: CGFloat
    
    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.bounds
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            let position = CGPoint(
                x: bounds.minX + result.positions[index].x,
                y: bounds.minY + result.positions[index].y
            )
            subview.place(at: position, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
}

struct FlowResult {
    let bounds: CGSize
    let positions: [CGPoint]
    let sizes: [CGSize]
    
    init(in maxWidth: CGFloat, subviews: LayoutSubviews, spacing: CGFloat) {
        var sizes: [CGSize] = []
        var positions: [CGPoint] = []
        
        var currentRowY: CGFloat = 0
        var currentRowX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentRowX + size.width > maxWidth && currentRowX > 0 {
                currentRowY += currentRowHeight + spacing
                currentRowX = 0
                currentRowHeight = 0
            }
            
            positions.append(CGPoint(x: currentRowX, y: currentRowY))
            sizes.append(size)
            
            currentRowX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        
        self.positions = positions
        self.sizes = sizes
        self.bounds = CGSize(
            width: maxWidth,
            height: currentRowY + currentRowHeight
        )
    }
}
