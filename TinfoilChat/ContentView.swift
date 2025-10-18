//
//  ContentView.swift
//  TinfoilChat
//
//  Created on 07/11/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import SwiftUI
import Clerk
import AVFoundation

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @EnvironmentObject private var authManager: AuthManager
    @StateObject private var chatViewModel = TinfoilChat.ChatViewModel()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @State private var showEncryptionAlert = false
    @State private var showKeyInputModal = false
    @State private var lastSyncTime: Date?
    
    var body: some View {
        Group {
            if authManager.isLoading {
                ZStack {
                    (colorScheme == .dark ? Color.backgroundPrimary : Color.white)
                        .ignoresSafeArea()
                    VStack(spacing: 24) {
                        Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 48)

                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .gray))
                            .scaleEffect(1.2)
                    }
                }
            } else {
                // Use the ChatContainer from ChatView.swift
                ChatContainer()
                    .environmentObject(chatViewModel)
            }
        }
        .onAppear {
            // Wire AuthManager to ChatViewModel early so migration prompt state is available
            chatViewModel.authManager = authManager
            authManager.setChatViewModel(chatViewModel)

            // Initialize encryption with existing key only (no auto-creation)
            Task {
                if EncryptionService.shared.hasEncryptionKey() {
                    _ = try? await EncryptionService.shared.initialize()
                }

                await MainActor.run {
                    // Update available models based on current auth status
                    chatViewModel.updateModelBasedOnAuthStatus(
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
        // Migration prompt for legacy local chats - use sheet to avoid dismissal during transitions/keyboard
        .sheet(isPresented: Binding(
            get: { chatViewModel.showMigrationPrompt },
            set: { newValue in chatViewModel.showMigrationPrompt = newValue }
        )) {
            MigrationPromptSheet(
                onDelete: { chatViewModel.confirmDeleteLegacyChats() },
                onSync: {
                    Task { await chatViewModel.confirmMigrateLegacyChats() }
                }
            )
            .interactiveDismissDisabled(true)
        }
        // After migration decision, show Import Encryption Key view if needed
        .sheet(isPresented: $showKeyInputModal) {
            EncryptionKeyInputView(isPresented: $showKeyInputModal) { importedKey in
                Task {
                    do {
                        // Use ChatViewModel API so it retries decryption of failed chats immediately
                        try await chatViewModel.setEncryptionKey(importedKey)
                        
                        // After setting key and decrypting, continue sign-in/sync flow
                        await MainActor.run {
                            chatViewModel.handleSignIn()
                        }
                    } catch {
                        await MainActor.run {
                            let alert = UIAlertController(
                                title: "Invalid Key",
                                message: "The encryption key format is invalid.",
                                preferredStyle: .alert
                            )
                            alert.addAction(UIAlertAction(title: "OK", style: .default))
                            
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let rootViewController = windowScene.windows.first?.rootViewController {
                                rootViewController.present(alert, animated: true)
                            }
                        }
                    }
                }
            }
        }
        // Relay view model's request to show key import view
        .onChange(of: chatViewModel.shouldShowKeyImport) { _, shouldShow in
            if shouldShow {
                // Dismiss keyboard then present key import sheet
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                showKeyInputModal = true
                // Reset the trigger on the next runloop to avoid re-entry
                DispatchQueue.main.async {
                    chatViewModel.shouldShowKeyImport = false
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && authManager.isAuthenticated {
                // Sync when app becomes active if authenticated
                // Only sync if it's been more than 30 seconds since last sync
                let shouldSync = lastSyncTime == nil || Date().timeIntervalSince(lastSyncTime!) > 30
                
                if shouldSync {
                    Task {
                        // Sync chats
                        await chatViewModel.performFullSync()
                        await MainActor.run {
                            lastSyncTime = Date()
                        }
                    }
                }
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
            // Update available models when auth status changes
            chatViewModel.updateModelBasedOnAuthStatus(
                isAuthenticated: isAuthenticated,
                hasActiveSubscription: authManager.hasActiveSubscription
            )
            
            // After auth becomes true, present encryption prompt only if
            // a) no key exists and b) we're not currently showing a migration prompt
            if isAuthenticated && !EncryptionService.shared.hasEncryptionKey() {
                let shouldShow = !(chatViewModel.showMigrationPrompt)
                if shouldShow {
                    showEncryptionAlert = true
                }
            }
            
            // Trigger initial sync when user becomes authenticated
            if isAuthenticated {
                print("ContentView: Calling handleSignIn because user is authenticated")
                chatViewModel.handleSignIn()
            }
        }
        // Ensure prompts/sync re-trigger after loading finishes (avoids dismissal during transition)
        .onChange(of: authManager.isLoading) { _, isLoading in
            if !isLoading {
                // Re-run sign-in flow to re-present migration prompt post-loading
                if authManager.isAuthenticated {
                    chatViewModel.handleSignIn()
                    // If still no key and not showing migration, show encryption prompt
                    if !(chatViewModel.showMigrationPrompt) && !EncryptionService.shared.hasEncryptionKey() {
                        showEncryptionAlert = true
                    }
                }
            }
        }
        // When migration prompt visibility changes, handle keyboard
        .onChange(of: chatViewModel.showMigrationPrompt) { _, isShowing in
            if isShowing {
                // Ensure keyboard is dismissed while sheet is visible
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: authManager.hasActiveSubscription) { _, hasSubscription in
            // Update available models when subscription status changes
            chatViewModel.updateModelBasedOnAuthStatus(
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
            // Use ChatViewModel API so it initializes encryption and retries any needed decryption flows
            try await chatViewModel.setEncryptionKey(newKey)
            
            // Show alert with the key to save
            await MainActor.run {
                showGeneratedKeyAlert(newKey)
                // Continue sign-in/sync flow once key is set
                chatViewModel.handleSignIn()
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
    
}

#Preview {
    ContentView()
        .environment(Clerk.shared)
}
