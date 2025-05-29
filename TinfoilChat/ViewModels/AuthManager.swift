//
//  AuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

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
        
        print("AuthManager initialized with authentication status: \(isAuthenticated)")
    }
    
    func setChatViewModel(_ viewModel: ChatViewModel) {
        self.chatViewModel = viewModel
    }
    
    private func loadCachedAuthState() {
        if let userData = UserDefaults.standard.data(forKey: userDataKey),
           let decodedUserData = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
            localUserData = decodedUserData
            print("AuthManager: Loaded cached user data")
        }
        
        isAuthenticated = UserDefaults.standard.bool(forKey: authStateKey)
        hasActiveSubscription = UserDefaults.standard.bool(forKey: subscriptionKey)
        
        print("AuthManager: Loaded cached auth state - isAuthenticated: \(isAuthenticated), hasSubscription: \(hasActiveSubscription)")
    }
    
    private func saveAuthState() {
        UserDefaults.standard.set(isAuthenticated, forKey: authStateKey)
        UserDefaults.standard.set(hasActiveSubscription, forKey: subscriptionKey)
        
        if let userData = localUserData {
            if let encodedData = try? JSONSerialization.data(withJSONObject: userData) {
                UserDefaults.standard.set(encodedData, forKey: userDataKey)
                print("AuthManager: Saved user data to UserDefaults")
            }
        } else {
            UserDefaults.standard.removeObject(forKey: userDataKey)
        }
        
        print("AuthManager: Saved auth state - isAuthenticated: \(isAuthenticated), hasSubscription: \(hasActiveSubscription)")
    }
    
    func setClerk(_ clerk: Clerk) {
        self.clerk = clerk
        // Check if clerk is already loaded and has a user
        if clerk.user != nil {
            self.isAuthenticated = true
            print("AuthManager: Clerk already authenticated")
            
            // Update user data immediately
            if let user = clerk.user {
                updateUserData(from: user)
                // Handle sign in for chat
                chatViewModel?.handleSignIn()
            }
        } else {
            print("AuthManager: Clerk not yet authenticated or loaded")
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
                
                print("AuthManager: Subscription status - \(hasActiveSubscription ? "Active" : "Inactive")")
                
                // Store in localUserData
                localUserData?["subscription_status"] = cleanedStatus
            } else {
                print("AuthManager: No chat_subscription_status found in metadata")
                hasActiveSubscription = false
            }
        } else {
            print("AuthManager: No public metadata found")
            hasActiveSubscription = false
        }
        
        // Save updated state to UserDefaults
        saveAuthState()
        
        // Handle chat state changes if authentication or subscription status changed
        if !wasAuthenticated && isAuthenticated {
            chatViewModel?.handleSignIn()
        }
    }
    
    func initializeAuthState() async {
        print("AuthManager: Starting auth state initialization")
        do {
            guard let clerk = self.clerk else {
                print("Error: Clerk instance not set")
                isLoading = false
                return
            }
            
            // Make sure Clerk is loaded
            if !clerk.isLoaded {
                print("AuthManager: Clerk not loaded, loading Clerk")
                try await clerk.load()
                print("AuthManager: Clerk loaded successfully")
            } else {
                print("AuthManager: Clerk already loaded")
            }
            
            // Update authentication status based on whether user is signed in
            let wasAuthenticated = isAuthenticated
            isAuthenticated = clerk.user != nil
            print("AuthManager: Authentication status: \(isAuthenticated)")
            
            // Get user data if authenticated
            if isAuthenticated, let user = clerk.user {
                updateUserData(from: user)
                print("AuthManager: User data loaded")
            } else {
                if wasAuthenticated {
                    // User was authenticated but isn't anymore
                    clearAuthState()
                }
                hasActiveSubscription = false
            }
            
            // Finish loading regardless of authentication state
            isLoading = false
            print("AuthManager: Finished loading - isLoading set to false")
            
        } catch {
            print("Error initializing auth state: \(error)")
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
        
        print("AuthManager: Cleared auth state")
    }
    
    func signOut() async {
        do {
            // If we have a Clerk instance, use it, otherwise fall back to Clerk.shared
            let clerk = self.clerk ?? Clerk.shared
            try await clerk.signOut()
            print("AuthManager: Successfully signed out")
            
            clearAuthState()
            
        } catch {
            print("Error signing out: \(error)")
        }
    }
    
    /// Forces a reload of the Clerk user data to refresh subscription status
    func forceRefreshUserData() async {
        guard let clerk = self.clerk else {
            print("Error: Clerk instance not set")
            return
        }
        
        do {
            print("AuthManager: Forcing reload of Clerk user data")
            try await clerk.load()
            
            if let user = clerk.user {
                print("AuthManager: Successfully reloaded user data for \(user.id)")
                updateUserData(from: user)
            } else {
                print("AuthManager: No user found after reload")
                clearAuthState()
            }
        } catch {
            print("Error reloading user data: \(error)")
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
            print("AuthManager: Successfully deleted user account")
            
            // Clear local state
            clearAuthState()
            
        } catch {
            print("Error deleting account: \(error)")
            throw error
        }
    }
} 
