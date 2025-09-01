//
//  AuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import Clerk
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
    
    // UserDefaults keys
    private let authStateKey = "sh.tinfoil.authState"
    private let userDataKey = "sh.tinfoil.userData"
    private let subscriptionKey = "sh.tinfoil.subscription"
    
    // Reference to ChatViewModel for handling chat state
    private weak var chatViewModel: ChatViewModel?
    
    init() {
        // Try to load cached auth state from UserDefaults
        loadCachedAuthState()
        
    }
    
    func setChatViewModel(_ viewModel: ChatViewModel) {
        self.chatViewModel = viewModel
        
        // If already authenticated, trigger handleSignIn
        if isAuthenticated {
            viewModel.handleSignIn()
        }
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
        if clerk.user != nil {
            self.isAuthenticated = true
            
            // Update user data immediately
            if let user = clerk.user {
                updateUserData(from: user)
                // Handle sign in for chat
                chatViewModel?.handleSignIn()
            }
        } else {
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
                // Convert to string and check if it contains "active"
                let statusString = "\(subscriptionStatus)"
                
                // Handle JSON string with quotes (e.g. "active" instead of active)
                let cleanedStatus = statusString.replacingOccurrences(of: "\"", with: "")
                hasActiveSubscription = cleanedStatus == "active"
                
                
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
            if let chatVM = chatViewModel {
                chatVM.handleSignIn()
            } else {
            }
        }
    }
    
    func initializeAuthState() async {
        do {
            guard let clerk = self.clerk else {
                isLoading = false
                return
            }
            
            // Make sure Clerk is loaded
            if !clerk.isLoaded {
                try await clerk.load()
            } else {
            }
            
            // Update authentication status based on whether user is signed in
            let wasAuthenticated = isAuthenticated
            isAuthenticated = clerk.user != nil
            
            // Get user data if authenticated
            if isAuthenticated, let user = clerk.user {
                updateUserData(from: user)
                
                // Log in to RevenueCat with Clerk user ID
                await RevenueCatManager.shared.loginUser(user.id)
            } else {
                if wasAuthenticated {
                    // User was authenticated but isn't anymore
                    clearAuthState()
                    
                    // Log out from RevenueCat
                    await RevenueCatManager.shared.logoutUser()
                }
                hasActiveSubscription = false
            }
            
            // Finish loading regardless of authentication state
            isLoading = false
            
        } catch {
            isLoading = false
        }
    }
    
    private func clearAuthState() {
        localUserData = nil
        isAuthenticated = false
        hasActiveSubscription = false
        
        // Clear saved auth state
        UserDefaults.standard.removeObject(forKey: authStateKey)
        UserDefaults.standard.removeObject(forKey: userDataKey)
        UserDefaults.standard.removeObject(forKey: subscriptionKey)
        
        // Handle chat state for sign out
        chatViewModel?.handleSignOut()
        
    }
    
    func signOut() async {
        do {
            // If we have a Clerk instance, use it, otherwise fall back to Clerk.shared
            let clerk = self.clerk ?? Clerk.shared
            try await clerk.signOut()
            
            clearAuthState()
            
        } catch {
        }
    }
    
    /// Fetches subscription status directly from the API
    func fetchSubscriptionStatus() async {
        guard let clerk = clerk else { return }
        guard let session = clerk.session else { return }
        guard let token = session.lastActiveToken?.jwt else { return }
        
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
                
                await MainActor.run {
                    let wasActive = self.hasActiveSubscription
                    self.hasActiveSubscription = (chatStatus == "active")
                    
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
                    
                    // Post notification that subscription status was updated
                    NotificationCenter.default.post(name: NSNotification.Name("SubscriptionStatusUpdated"), object: nil)
                    
                    // If subscription became active, clear cached API key to force refetch
                    if self.hasActiveSubscription && !wasActive {
                        APIKeyManager.shared.clearApiKey()
                        
                        // Proactively fetch new API key
                        Task {
                            let _ = await APIKeyManager.shared.getApiKey()
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
