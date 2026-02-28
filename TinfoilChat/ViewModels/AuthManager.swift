//
//  AuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import Combine

@MainActor
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var localUserData: [String: Any]? = nil
    @Published var hasActiveSubscription = false
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var clerk: Clerk?
    private var hasTriggeredSignIn = false
    
    // UserDefaults keys
    private let authStateKey = "sh.tinfoil.authState"
    private let userDataKey = "sh.tinfoil.userData"
    private let subscriptionKey = "sh.tinfoil.subscription"

    private func isSubscriptionActive(status: String, expiresAt: String?) -> Bool {
        if status == "active" || status == "trialing" {
            return true
        }

        if status == "canceled", let expiresAt = expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let expirationDate = formatter.date(from: expiresAt) {
                return expirationDate > Date()
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let expirationDate = formatter.date(from: expiresAt) {
                return expirationDate > Date()
            }
        }

        return false
    }
    
    // Reference to ChatViewModel for handling chat state
    private weak var chatViewModel: ChatViewModel?
    
    init() {
        // Try to load cached auth state from UserDefaults
        loadCachedAuthState()
        
    }
    
    func setChatViewModel(_ viewModel: ChatViewModel) {
        self.chatViewModel = viewModel
        
        // If already authenticated and clerk is set, trigger handleSignIn once
        // This handles the case where AuthManager loads before ChatViewModel
        if isAuthenticated, clerk != nil, clerk?.user != nil, !hasTriggeredSignIn {
            hasTriggeredSignIn = true
            viewModel.handleSignIn()
        }
        // Otherwise handleSignIn will be called from setClerk when authentication is confirmed
    }
    
    private func loadCachedAuthState() {
        if let userData = UserDefaults.standard.data(forKey: userDataKey),
           let decodedUserData = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
            localUserData = decodedUserData
        }
        
        isAuthenticated = UserDefaults.standard.bool(forKey: authStateKey)
        hasActiveSubscription = UserDefaults.standard.bool(forKey: subscriptionKey)
        
    }
    
    private func saveAuthState() {
        UserDefaults.standard.set(isAuthenticated, forKey: authStateKey)
        UserDefaults.standard.set(hasActiveSubscription, forKey: subscriptionKey)
        
        if let userData = localUserData {
            if let encodedData = try? JSONSerialization.data(withJSONObject: userData) {
                UserDefaults.standard.set(encodedData, forKey: userDataKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: userDataKey)
        }
        
    }
    
    func setClerk(_ clerk: Clerk) {
        self.clerk = clerk
        // Check if clerk is already loaded and has a user
        if let user = clerk.user {
            // Update user data BEFORE setting isAuthenticated
            updateUserData(from: user)
            
            // Now set authenticated, which will trigger observers
            self.isAuthenticated = true
            
            // Handle sign in for chat if not already triggered
            if !hasTriggeredSignIn, let chatVM = chatViewModel {
                hasTriggeredSignIn = true
                chatVM.handleSignIn()
            }
        }
    }
    
    private func updateUserData(from user: User) {
        let wasAuthenticated = isAuthenticated
        
        // Store relevant user data
        localUserData = [
            "id": user.id,
            "email": user.primaryEmailAddress?.emailAddress ?? "",
            "name": user.firstName ?? "",
            "fullName": "\(user.firstName ?? "") \(user.lastName ?? "")",
            "imageUrl": user.imageUrl
        ]
        
        // Store subscription status if it exists
        if let publicMetadata = user.publicMetadata {
            // Check for subscription status in public metadata
            if let subscriptionStatus = publicMetadata["chat_subscription_status"] {
                let statusString = "\(subscriptionStatus)"
                let cleanedStatus = statusString.replacingOccurrences(of: "\"", with: "")

                var expiresAt: String? = nil
                if let expiresAtValue = publicMetadata["chat_subscription_expires_at"] {
                    let expiresAtString = "\(expiresAtValue)"
                    expiresAt = expiresAtString.replacingOccurrences(of: "\"", with: "")
                }

                hasActiveSubscription = isSubscriptionActive(status: cleanedStatus, expiresAt: expiresAt)

                // Store in localUserData
                localUserData?["subscription_status"] = cleanedStatus
            } else {
                hasActiveSubscription = false
            }
        } else {
            hasActiveSubscription = false
        }
        
        // Save updated state to UserDefaults
        saveAuthState()
        
        // Handle chat state changes if authentication or subscription status changed
        if !wasAuthenticated && isAuthenticated {
            if !hasTriggeredSignIn, let chatVM = chatViewModel {
                hasTriggeredSignIn = true
                chatVM.handleSignIn()
            }
        }
    }
    
    func initializeAuthState() async {
        guard let clerk = self.clerk else {
            isLoading = false
            return
        }

        do {
            if !clerk.isLoaded {
                try await clerk.refreshClient()
            }
        } catch {
            // Network or other error loading Clerk - preserve cached auth state
            // User will remain "authenticated" based on cached state until we can verify
            isLoading = false
            return
        }

        // Clerk loaded successfully - now we can trust clerk.user state
        let wasAuthenticated = isAuthenticated

        if let user = clerk.user {
            isAuthenticated = true
            updateUserData(from: user)
            await RevenueCatManager.shared.loginUser(user.id)
        } else {
            if wasAuthenticated {
                // User was authenticated but Clerk confirms they're no longer signed in.
                // clearAuthState calls handleSignOut first (while auth is still true)
                // so that local chats can be saved to disk before clearing.
                clearAuthState()
                await RevenueCatManager.shared.logoutUser()
            } else {
                isAuthenticated = false
            }
            hasActiveSubscription = false
        }

        isLoading = false
    }
    
    private func clearAuthState() {
        // Handle chat state BEFORE clearing auth so the view model can still
        // save the current chat (hasChatAccess depends on isAuthenticated).
        chatViewModel?.handleSignOut()

        localUserData = nil
        isAuthenticated = false
        hasActiveSubscription = false
        hasTriggeredSignIn = false  // Reset the flag on sign out

        // Clear saved auth state
        UserDefaults.standard.removeObject(forKey: authStateKey)
        UserDefaults.standard.removeObject(forKey: userDataKey)
        UserDefaults.standard.removeObject(forKey: subscriptionKey)

    }
    
    func signOut() async {
        do {
            // If we have a Clerk instance, use it, otherwise fall back to Clerk.shared
            let clerk = self.clerk ?? Clerk.shared
            try await clerk.auth.signOut()
            
            clearAuthState()
            
        } catch {
        }
    }
    
    /// Fetches subscription status directly from the API
    func fetchSubscriptionStatus() async {
        guard let clerk = clerk else { return }
        guard let session = clerk.session else { return }
        guard let token = try? await session.getToken() ?? session.lastActiveToken?.jwt else { return }
        
        do {
            let apiURL = "\(Constants.API.baseURL)/api/app/user-metadata"
            
            guard let url = URL(string: apiURL) else { return }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let publicMetadata = json["public_metadata"] as? [String: Any],
               let chatStatus = publicMetadata["chat_subscription_status"] as? String {
                let expiresAt = publicMetadata["chat_subscription_expires_at"] as? String

                await MainActor.run {
                    let wasActive = self.hasActiveSubscription
                    self.hasActiveSubscription = self.isSubscriptionActive(status: chatStatus, expiresAt: expiresAt)

                    // Update local user data
                    if self.localUserData != nil {
                        self.localUserData?["subscription_status"] = chatStatus
                    }
                    
                    // Update UserDefaults
                    if let userData = self.localUserData,
                       let encodedData = try? JSONSerialization.data(withJSONObject: userData) {
                        UserDefaults.standard.set(encodedData, forKey: userDataKey)
                    }
                    
                    // Save subscription state
                    UserDefaults.standard.set(self.hasActiveSubscription, forKey: self.subscriptionKey)
                    
                    // Post notification only when subscription status actually changed
                    if self.hasActiveSubscription != wasActive {
                        NotificationCenter.default.post(name: NSNotification.Name("SubscriptionStatusUpdated"), object: nil)
                    }

                    // If subscription became active, clear cached session token to force refetch
                    if self.hasActiveSubscription && !wasActive {
                        SessionTokenManager.shared.clearSessionToken()

                        // Proactively fetch new session token
                        Task {
                            let _ = await SessionTokenManager.shared.getSessionToken()
                        }
                    }
                }
            }
        } catch {
            // Handle error silently - subscription status will remain unchanged
        }
    }
    
    /// Deletes the user's account and clears all local data
    func deleteAccount() async throws {
        do {
            guard let clerk = self.clerk else {
                throw NSError(domain: "AuthError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Clerk instance not set"])
            }
            
            guard let user = clerk.user else {
                throw NSError(domain: "AuthError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No user found"])
            }
            
            // Delete the user's account
            try await user.delete()
            
            // Clear local state
            clearAuthState()
            
        } catch {
            throw error
        }
    }
} 
