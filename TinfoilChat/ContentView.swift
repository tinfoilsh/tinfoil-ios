//
//  ContentView.swift
//  TinfoilChat
//
//  Created by Sacha  on 2/25/25.
//

import SwiftUI
import Clerk

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @EnvironmentObject private var authManager: AuthManager
    @State private var chatViewModel: TinfoilChat.ChatViewModel?
    @Environment(\.colorScheme) var colorScheme
    @State private var showEncryptionAlert = false
    @State private var showKeyInputModal = false
    @State private var newKeyInput: String = ""
    @State private var keyError: String? = nil
    @State private var isKeyVisible: Bool = false
    @FocusState private var isKeyFieldFocused: Bool
    
    var body: some View {
        Group {
            if authManager.isLoading {
                ZStack {
                    Color(hex: "111827")
                        .ignoresSafeArea()
                    VStack(spacing: 24) {
                        Image("navbar-logo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 48)
                        
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                    }
                }
            } else if let chatViewModel = chatViewModel {
                // Use the ChatContainer from ChatView.swift
                ChatContainer()
                    .environmentObject(chatViewModel)
            }
        }
        .onAppear {
            // Check for encryption key on first launch
            Task {
                // Check if we have an encryption key
                let hasKey = EncryptionService.shared.hasEncryptionKey()
                
                await MainActor.run {
                    // Only show encryption setup for authenticated users without a key
                    if !hasKey && authManager.isAuthenticated {
                        // No key exists and user is logged in, show alert
                        showEncryptionAlert = true
                    } else if hasKey {
                        // Initialize encryption with existing key if it exists
                        Task {
                            _ = try? await EncryptionService.shared.initialize()
                        }
                    }
                    
                    // Create ChatViewModel with authManager
                    if chatViewModel == nil {
                        let vm = TinfoilChat.ChatViewModel(authManager: authManager)
                        chatViewModel = vm
                        // Set up bidirectional reference
                        authManager.setChatViewModel(vm)
                    }
                    
                    // Update available models based on current auth status
                    chatViewModel?.updateModelBasedOnAuthStatus(
                        isAuthenticated: authManager.isAuthenticated,
                        hasActiveSubscription: authManager.hasActiveSubscription
                    )
                }
            }
        }
        .alert("Set Up Encryption", isPresented: $showEncryptionAlert) {
            Button("Generate New Key") {
                Task {
                    await generateNewKey()
                }
            }
            Button("Import Existing Key") {
                showKeyInputModal = true
            }
        } message: {
            Text("Your chats are encrypted end-to-end and backed up. Choose how to set up your encryption key.")
        }
        .sheet(isPresented: $showKeyInputModal) {
            NavigationView {
                VStack(spacing: 20) {
                    HStack {
                        if isKeyVisible {
                            TextField("Enter encryption key (key_...)", text: $newKeyInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .font(.system(.body, design: .monospaced))
                                .focused($isKeyFieldFocused)
                                .onChange(of: newKeyInput) { _, newValue in
                                    validateKey(newValue)
                                }
                        } else {
                            SecureField("Enter encryption key (key_...)", text: $newKeyInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .font(.system(.body, design: .monospaced))
                                .focused($isKeyFieldFocused)
                                .onChange(of: newKeyInput) { _, newValue in
                                    validateKey(newValue)
                                }
                        }
                        
                        Button(action: {
                            isKeyVisible.toggle()
                        }) {
                            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let error = keyError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    Button("Import Key") {
                        if keyError == nil {
                            importEncryptionKey()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(newKeyInput.isEmpty || keyError != nil ? Color.gray : Color.accentPrimary)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(newKeyInput.isEmpty || keyError != nil)
                    
                    Spacer()
                }
                .padding()
                .navigationTitle("Import Encryption Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showKeyInputModal = false
                            newKeyInput = ""
                            keyError = nil
                        }
                    }
                }
                .onAppear {
                    // Automatically focus the text field and show keyboard
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isKeyFieldFocused = true
                    }
                }
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
            print("ContentView: authManager.isAuthenticated changed to \(isAuthenticated)")
            
            // Update available models when auth status changes
            chatViewModel?.updateModelBasedOnAuthStatus(
                isAuthenticated: isAuthenticated,
                hasActiveSubscription: authManager.hasActiveSubscription
            )
            
            // Check for encryption key when user logs in
            if isAuthenticated && !EncryptionService.shared.hasEncryptionKey() {
                showEncryptionAlert = true
            }
            
            // Trigger initial sync when user becomes authenticated
            if isAuthenticated {
                print("ContentView: Calling handleSignIn because user is authenticated")
                chatViewModel?.handleSignIn()
            }
        }
        .onChange(of: authManager.hasActiveSubscription) { _, hasSubscription in
            // Update available models when subscription status changes
            chatViewModel?.updateModelBasedOnAuthStatus(
                isAuthenticated: authManager.isAuthenticated,
                hasActiveSubscription: hasSubscription
            )
        }
    }
    
    // MARK: - Helper Functions
    
    private func generateNewKey() async {
        do {
            // Generate new key
            let newKey = EncryptionService.shared.generateKey()
            try EncryptionService.shared.saveKeyToKeychain(newKey)
            try await EncryptionService.shared.setKey(newKey)
            
            // Show alert with the key to save
            await MainActor.run {
                showGeneratedKeyAlert(newKey)
            }
        } catch {
            print("Failed to generate encryption key: \(error)")
        }
    }
    
    private func showGeneratedKeyAlert(_ key: String) {
        let alert = UIAlertController(
            title: "Encryption Key Created",
            message: "Save this key to sync your chats across devices:\n\n\(key)\n\n⚠️ Store this key securely. You'll need it to access your chats on other devices.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Copy Key", style: .default) { _ in
            UIPasteboard.general.string = key
        })
        
        alert.addAction(UIAlertAction(title: "Continue", style: .cancel))
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }
    
    private func validateKey(_ key: String) {
        // Reset error first
        keyError = nil
        
        // Check if key is empty
        if key.isEmpty {
            return
        }
        
        // Check if key has the required prefix
        if !key.hasPrefix("key_") {
            keyError = "Key must start with 'key_' prefix"
            return
        }
        
        // Validate key characters (after prefix)
        let keyWithoutPrefix = String(key.dropFirst(4))
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if keyWithoutPrefix.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
            keyError = "Key must only contain lowercase letters and numbers after the prefix"
            return
        }
        
        // Validate key length
        if keyWithoutPrefix.count % 2 != 0 {
            keyError = "Invalid key length"
            return
        }
    }
    
    private func importEncryptionKey() {
        let keyToSet = newKeyInput
        
        // Validate one more time before proceeding
        validateKey(keyToSet)
        if keyError != nil {
            return
        }
        
        // Dismiss modal and process key
        showKeyInputModal = false
        
        Task {
            do {
                // Use existing key
                try await EncryptionService.shared.setKey(keyToSet)
                
                await MainActor.run {
                    newKeyInput = ""
                    keyError = nil
                }
            } catch {
                await MainActor.run {
                    // Show error alert
                    let alert = UIAlertController(
                        title: "Invalid Key",
                        message: "The encryption key format is invalid. Keys must start with 'key_' followed by alphanumeric characters.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootViewController = windowScene.windows.first?.rootViewController {
                        rootViewController.present(alert, animated: true)
                    }
                    
                    newKeyInput = ""
                    keyError = nil
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(Clerk.shared)
}
