//
//  AuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import Combine

enum SubscriptionAccessPolicy {
    static func requiresCredentialRefresh(previous: Bool, current: Bool) -> Bool {
        previous != current
    }

    static func expirationDate(from expiresAt: String?) -> Date? {
        guard let expiresAt, !expiresAt.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let expirationDate = formatter.date(from: expiresAt) {
            return expirationDate
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }

    static func isActive(status: String?, expiresAt: String?, now: Date = Date()) -> Bool {
        switch status {
        case "active", "trialing":
            guard let expiresAt, !expiresAt.isEmpty else { return true }
            guard let expirationDate = expirationDate(from: expiresAt) else { return false }
            return expirationDate > now
        case "canceled":
            guard let expirationDate = expirationDate(from: expiresAt) else { return false }
            return expirationDate > now
        default:
            return false
        }
    }

    static func scheduledExpiration(status: String?, expiresAt: String?, now: Date = Date()) -> Date? {
        guard isActive(status: status, expiresAt: expiresAt, now: now),
              let expirationDate = expirationDate(from: expiresAt) else { return nil }
        return expirationDate
    }
}

struct SubscriptionRefreshContext: Equatable {
    let userId: String
    let accountLifecycleGeneration: UInt

    func isCurrent(userId: String?, accountLifecycleGeneration: UInt) -> Bool {
        self.userId == userId && self.accountLifecycleGeneration == accountLifecycleGeneration
    }
}

@MainActor
class AuthManager: ObservableObject {
    private static let userIdKey = "id"

    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var localUserData: [String: Any]? = nil
    @Published var hasActiveSubscription = false

    var localUserId: String? {
        localUserData?[Self.userIdKey] as? String
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var clerk: Clerk?
    private var hasTriggeredSignIn = false
    private var accountSwitchTask: Task<Void, Never>?
    private var accountTeardownTask: Task<Void, Never>?
    private var accountTeardownId: UUID?
    private var subscriptionExpiryTask: Task<Void, Never>?
    private var subscriptionExpiryTaskId: UUID?
    private var accountLifecycleGeneration: UInt = 0
    
    // UserDefaults keys
    private let authStateKey = Constants.StorageKeys.Auth.state
    private let userDataKey = Constants.StorageKeys.Auth.userData
    private let subscriptionKey = Constants.StorageKeys.Auth.subscription

    private func applySubscriptionAccess(_ isActive: Bool) {
        let shouldRefreshCredentials = SubscriptionAccessPolicy.requiresCredentialRefresh(
            previous: hasActiveSubscription,
            current: isActive
        )
        hasActiveSubscription = isActive
        guard shouldRefreshCredentials else { return }

        Task {
            let token = await SessionTokenManager.shared.fetchFreshSessionToken()
            if token.isEmpty {
                SessionTokenManager.shared.clearSessionToken()
            }
        }
    }

    private func updateSubscriptionAccess(status: String?, expiresAt: String?) {
        let now = Date()
        applySubscriptionAccess(SubscriptionAccessPolicy.isActive(
            status: status,
            expiresAt: expiresAt,
            now: now
        ))
        scheduleSubscriptionExpiration(status: status, expiresAt: expiresAt, now: now)
    }

    private func scheduleSubscriptionExpiration(status: String?, expiresAt: String?, now: Date) {
        cancelSubscriptionExpiration()
        guard let expirationDate = SubscriptionAccessPolicy.scheduledExpiration(
            status: status,
            expiresAt: expiresAt,
            now: now
        ) else { return }

        let taskId = UUID()
        let delay = expirationDate.timeIntervalSince(now)
        subscriptionExpiryTaskId = taskId
        subscriptionExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.subscriptionExpiryTaskId == taskId else { return }
            self.subscriptionExpiryTask = nil
            self.subscriptionExpiryTaskId = nil
            self.applySubscriptionAccess(false)
            self.saveAuthState()
        }
    }

    private func cancelSubscriptionExpiration() {
        subscriptionExpiryTask?.cancel()
        subscriptionExpiryTask = nil
        subscriptionExpiryTaskId = nil
    }

    private func invalidateAccountLifecycle() {
        accountLifecycleGeneration &+= 1
    }

    private func isCurrentSubscriptionRefresh(
        _ context: SubscriptionRefreshContext,
        clerk expectedClerk: Clerk
    ) -> Bool {
        clerk === expectedClerk
            && expectedClerk.user?.id == context.userId
            && context.isCurrent(
                userId: localUserId,
                accountLifecycleGeneration: accountLifecycleGeneration
            )
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
        updateSubscriptionAccess(
            status: localUserData?["subscription_status"] as? String,
            expiresAt: localUserData?["subscription_expires_at"] as? String
        )
        
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
        if self.clerk !== clerk {
            invalidateAccountLifecycle()
        }
        self.clerk = clerk
        // Check if clerk is already loaded and has a user
        if let user = clerk.user {
            if let cachedUserId = localUserId,
               cachedUserId != user.id {
                invalidateAccountLifecycle()
                hasTriggeredSignIn = true
                accountSwitchTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.clearAuthState()
                    await RevenueCatManager.shared.logoutUser()
                    // A sign-out may have completed while the cleanup
                    // above was suspended; only restore auth state when
                    // Clerk still reports the captured user.
                    guard self.clerk?.user?.id == user.id else { return }
                    self.updateUserData(from: user)
                    self.isAuthenticated = true
                    self.saveAuthState()
                    await RevenueCatManager.shared.loginUser(user.id)
                    guard self.clerk?.user?.id == user.id else { return }
                    if !self.hasTriggeredSignIn,
                       let chatVM = self.chatViewModel {
                        self.hasTriggeredSignIn = true
                        chatVM.handleSignIn()
                    }
                }
                return
            }
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
            Self.userIdKey: user.id,
            "email": user.primaryEmailAddress?.emailAddress ?? "",
            "name": user.firstName ?? "",
            "fullName": "\(user.firstName ?? "") \(user.lastName ?? "")",
            "imageUrl": user.imageUrl,
            "hasImage": user.hasImage
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

                updateSubscriptionAccess(
                    status: cleanedStatus,
                    expiresAt: expiresAt
                )

                // Store in localUserData
                localUserData?["subscription_status"] = cleanedStatus
                if let expiresAt {
                    localUserData?["subscription_expires_at"] = expiresAt
                }
            } else {
                updateSubscriptionAccess(status: nil, expiresAt: nil)
            }
        } else {
            updateSubscriptionAccess(status: nil, expiresAt: nil)
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

        if let accountSwitchTask {
            await accountSwitchTask.value
            self.accountSwitchTask = nil
        }

        // Clerk loaded successfully - now we can trust clerk.user state
        let wasAuthenticated = isAuthenticated

        if let user = clerk.user {
            if let cachedUserId = localUserId,
               cachedUserId != user.id {
                await clearAuthState()
                await RevenueCatManager.shared.logoutUser()
            }
            isAuthenticated = true
            updateUserData(from: user)
            await RevenueCatManager.shared.loginUser(user.id)
        } else {
            if wasAuthenticated {
                // User was authenticated but Clerk confirms they're no longer signed in.
                // clearAuthState calls handleSignOut first (while auth is still true)
                // so that local chats can be saved to disk before clearing.
                await clearAuthState()
                await RevenueCatManager.shared.logoutUser()
            } else {
                isAuthenticated = false
            }
            cancelSubscriptionExpiration()
            hasActiveSubscription = false
        }

        isLoading = false
    }
    
    private func clearAuthState() async {
        invalidateAccountLifecycle()
        if let accountTeardownTask {
            await accountTeardownTask.value
            return
        }

        let teardownId = UUID()
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAccountTeardown()
            self.chatViewModel?.completeAccountTeardown()
        }
        accountTeardownId = teardownId
        accountTeardownTask = teardownTask
        await teardownTask.value
        guard accountTeardownId == teardownId else { return }
        accountTeardownTask = nil
        accountTeardownId = nil
    }

    private func performAccountTeardown() async {
        // Handle chat state BEFORE clearing auth so the view model can still
        // save the current chat (hasChatAccess depends on isAuthenticated).
        await chatViewModel?.handleSignOut()
        await ChatRecoveryCoordinator.shared.reset(accountId: nil)

        // Sign-out performs a full local wipe so that no content, encryption
        // keys, or personalization bleed into the next account on a shared
        // device. This runs before isAuthenticated is cleared below so the
        // view model can still resolve the signing-out user's id for the wipe.
        chatViewModel?.resetSharedProfileSettingsForAccountTeardown()
        // Reset shared settings before the profile wipe so observer-triggered
        // profile writes are deleted by the final teardown operation.
        SettingsManager.shared.clearAllSettings()
        await ProfileManager.shared.clearLocalProfileForAccountRemoval()
        if let chatViewModel {
            await chatViewModel.wipeLocalChatsForSignOut()
        } else {
            // No chat view model is attached (e.g. sign-out resolved before
            // the UI wired one up); run the same sync teardown handleSignOut
            // performs via clearSyncStatus — fencing in-flight sync,
            // clearing the checkpoint, and resetting the attested client —
            // and only then wipe the files, so a racing sync pass cannot
            // recreate them after the wipe.
            await CloudSyncService.shared.clearSyncStatus(forUser: localUserId)
            await Chat.deleteAllChatsFromStorage(userId: localUserId)
        }
        EncryptionService.shared.clearKey()
        await DeviceEncryptionService.shared.clearKey()
        cancelSubscriptionExpiration()
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
        invalidateAccountLifecycle()
        do {
            // If we have a Clerk instance, use it, otherwise fall back to Clerk.shared
            let clerk = self.clerk ?? Clerk.shared
            try await clerk.auth.signOut()
        } catch {
        }
        await clearAuthState()
    }
    
    /// Fetches subscription status directly from the API
    @discardableResult
    func fetchSubscriptionStatus() async -> Bool {
        guard let expectedClerk = clerk,
              let expectedUserId = expectedClerk.user?.id,
              expectedUserId == localUserId else { return false }
        let refreshContext = SubscriptionRefreshContext(
            userId: expectedUserId,
            accountLifecycleGeneration: accountLifecycleGeneration
        )
        guard let session = expectedClerk.session else { return false }
        guard let token = try? await session.getToken() ?? session.lastActiveToken?.jwt else { return false }
        guard isCurrentSubscriptionRefresh(refreshContext, clerk: expectedClerk) else { return false }
        
        do {
            let apiURL = "\(Constants.API.baseURL)/api/app/user-metadata"
            
            guard let url = URL(string: apiURL) else { return false }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard isCurrentSubscriptionRefresh(refreshContext, clerk: expectedClerk) else { return false }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let publicMetadata = json["public_metadata"] as? [String: Any] ?? [:]
                let chatStatus = publicMetadata["chat_subscription_status"] as? String
                let expiresAt = publicMetadata["chat_subscription_expires_at"] as? String

                guard isCurrentSubscriptionRefresh(refreshContext, clerk: expectedClerk) else { return false }
                updateSubscriptionAccess(
                    status: chatStatus,
                    expiresAt: expiresAt
                )

                // Update local user data
                if localUserData != nil {
                    if let chatStatus {
                        localUserData?["subscription_status"] = chatStatus
                    } else {
                        localUserData?.removeValue(forKey: "subscription_status")
                    }
                    if let expiresAt {
                        localUserData?["subscription_expires_at"] = expiresAt
                    } else {
                        localUserData?.removeValue(forKey: "subscription_expires_at")
                    }
                }

                // Update UserDefaults
                if let userData = localUserData,
                   let encodedData = try? JSONSerialization.data(withJSONObject: userData) {
                    UserDefaults.standard.set(encodedData, forKey: userDataKey)
                }

                // Save subscription state
                UserDefaults.standard.set(hasActiveSubscription, forKey: subscriptionKey)

                return true
            }
            return false
        } catch {
            // Handle error silently - subscription status will remain unchanged
            return false
        }
    }
    
    /// Deletes the user's account and clears all local data
    func deleteAccount() async throws {
        invalidateAccountLifecycle()
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
            await clearAuthState()
            
        } catch {
            throw error
        }
    }
} 
