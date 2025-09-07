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
    @State private var chatViewModel: TinfoilChat.ChatViewModel?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @State private var showEncryptionAlert = false
    @State private var showKeyInputModal = false
    @State private var lastSyncTime: Date?
    
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
            EncryptionKeyInputView(isPresented: $showKeyInputModal) { importedKey in
                Task {
                    do {
                        try await EncryptionService.shared.setKey(importedKey)
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && authManager.isAuthenticated {
                // Sync when app becomes active if authenticated
                // Only sync if it's been more than 30 seconds since last sync
                let shouldSync = lastSyncTime == nil || Date().timeIntervalSince(lastSyncTime!) > 30
                
                if shouldSync {
                    Task {
                        // Sync chats
                        await chatViewModel?.performFullSync()
                        await MainActor.run {
                            lastSyncTime = Date()
                        }
                    }
                }
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
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
    
}

#Preview {
    ContentView()
        .environment(Clerk.shared)
}
