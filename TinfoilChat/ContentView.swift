//
//  ContentView.swift
//  TinfoilChat
//
//  Created on 07/11/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import SwiftUI
import ClerkKit
import AVFoundation

struct ContentView: View {
    @Environment(Clerk.self) private var clerk
    @EnvironmentObject private var authManager: AuthManager
    @StateObject private var chatViewModel = TinfoilChat.ChatViewModel()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
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
            chatViewModel.authManager = authManager
            authManager.setChatViewModel(chatViewModel)

            // Initialize encryption with existing key only (no auto-creation)
            Task {
                if EncryptionService.shared.hasEncryptionKey() {
                    _ = try? await EncryptionService.shared.initialize()
                }

                await MainActor.run {
                    chatViewModel.updateModelBasedOnAuthStatus(
                        isAuthenticated: authManager.isAuthenticated,
                        hasActiveSubscription: authManager.hasActiveSubscription
                    )
                }
            }
        }
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
            chatViewModel.updateModelBasedOnAuthStatus(
                isAuthenticated: isAuthenticated,
                hasActiveSubscription: authManager.hasActiveSubscription
            )

            if isAuthenticated {
                chatViewModel.handleSignIn()
            }
        }
        .onChange(of: authManager.isLoading) { _, isLoading in
            if !isLoading && authManager.isAuthenticated {
                chatViewModel.handleSignIn()
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
    
    
}

#Preview {
    ContentView()
        .environment(Clerk.shared)
}
