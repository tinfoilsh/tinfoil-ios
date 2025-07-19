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
    @StateObject private var chatViewModel = TinfoilChat.ChatViewModel()
    @Environment(\.colorScheme) var colorScheme
    
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
            } else {
                // Use the ChatContainer from ChatView.swift
                ChatContainer()
                    .environmentObject(chatViewModel)
            }
        }
        .onAppear {
            // Pass the AuthManager to the ChatViewModel
            chatViewModel.authManager = authManager
            // Set up bidirectional reference
            authManager.setChatViewModel(chatViewModel)
            
            // Update available models based on current auth status
            chatViewModel.updateModelBasedOnAuthStatus(
                isAuthenticated: authManager.isAuthenticated,
                hasActiveSubscription: authManager.hasActiveSubscription
            )
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
            // Update available models when auth status changes
            chatViewModel.updateModelBasedOnAuthStatus(
                isAuthenticated: isAuthenticated,
                hasActiveSubscription: authManager.hasActiveSubscription
            )
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
