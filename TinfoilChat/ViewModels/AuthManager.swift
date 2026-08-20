//
//  AuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import Combine
import Sentry

enum AuthHydrationOutcome: Equatable {
    case signedOut
    case signedOutPreservingAccount
    case authenticated
    case accountSwitch

    static func resolve(
        lastOwnerUserId: String?,
        clerkUserId: String?
    ) -> Self {
        guard let clerkUserId else {
            return lastOwnerUserId == nil ? .signedOut : .signedOutPreservingAccount
        }
        if let lastOwnerUserId, lastOwnerUserId != clerkUserId {
            return .accountSwitch
        }
        return .authenticated
    }

    var requiresAccountTeardown: Bool {
        self == .accountSwitch
    }
}

struct AuthHydrationGeneration {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value += 1
        return value
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == value
    }
}

enum AccountTeardownTrigger: Equatable {
    case explicitSignOut
    case accountDeletion(deletedUserId: String)
    case accountSwitch(previousUserId: String, newUserId: String)

    func isConfirmed(currentClerkUserId: String?) -> Bool {
        switch self {
        case .explicitSignOut:
            return true
        case .accountDeletion(let deletedUserId):
            return currentClerkUserId == nil || currentClerkUserId == deletedUserId
        case .accountSwitch(let previousUserId, let newUserId):
            return previousUserId != newUserId && currentClerkUserId == nil
        }
    }

    func ownerUserId(retainedOwnerUserId: String?) -> String? {
        switch self {
        case .explicitSignOut:
            return retainedOwnerUserId
        case .accountDeletion(let deletedUserId):
            return deletedUserId
        case .accountSwitch(let previousUserId, _):
            return previousUserId
        }
    }
}

enum AccountTeardownRetryReason: Equatable {
    case accountSwitchConfirmation(AccountTeardownTrigger)
    case teardownFailure(AccountTeardownTrigger)

    var trigger: AccountTeardownTrigger {
        switch self {
        case .accountSwitchConfirmation(let trigger), .teardownFailure(let trigger):
            return trigger
        }
    }

    var requiresClerkSignOut: Bool {
        if case .accountSwitchConfirmation = self {
            return true
        }
        return false
    }
}

@MainActor
class AuthManager: ObservableObject {
    private static let userIdKey = "id"
    private static let accountSwitchMessage = "Tinfoil found a different signed-in account. Account actions remain paused to protect your data. Retry cleanup to sign out the current account, clear the previous account's local data, then sign in again."
    private static let accountSwitchSignOutFailureMessage = "Tinfoil couldn't sign out the current account. No local data was cleared. Check your connection and retry."

    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var localUserData: [String: Any]? = nil
    @Published var hasActiveSubscription = false
    @Published var accountTeardownError: String?
    @Published var isSessionUnavailable = false
    @Published private(set) var isAccountDataAccessReady = false

    var localUserId: String? {
        localUserData?[Self.userIdKey] as? String
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var clerk: Clerk?
    private var hasTriggeredSignIn = false
    private var accountTeardownTask: Task<Bool, Never>?
    private var accountTeardownId: UUID?
    private var pendingAccountTeardownRetryReason: AccountTeardownRetryReason?
    private var isAccountTeardownInProgress = false
    private var retainedOwnerUserId: String?
    private var authHydrationGeneration = AuthHydrationGeneration()
    
    // UserDefaults keys
    private let authStateKey = Constants.StorageKeys.Auth.state
    private let userDataKey = Constants.StorageKeys.Auth.userData
    private let subscriptionKey = Constants.StorageKeys.Auth.subscription

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
            retainedOwnerUserId = decodedUserData[Self.userIdKey] as? String
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
        guard !isAccountTeardownInProgress else { return }
        let hydrationToken = beginAuthTransition()
        self.clerk = clerk
        clearAccountSwitchFenceIfOwnerReturned(currentClerkUserId: clerk.user?.id)
        if isAccountSwitchConfirmationPending {
            isAuthenticated = false
            hasActiveSubscription = false
            hasTriggeredSignIn = false
            saveAuthState()
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentAuthTransition(hydrationToken) else { return }
                await self.chatViewModel?.handlePassiveAuthLoss()
            }
            return
        }
        // Check if clerk is already loaded and has a user
        if let user = clerk.user {
            guard isCurrentAuthTransition(hydrationToken) else { return }
            isSessionUnavailable = false
            if let cachedUserId = localUserId,
               cachedUserId != user.id {
                retainedOwnerUserId = cachedUserId
                isAuthenticated = false
                hasActiveSubscription = false
                hasTriggeredSignIn = false
                saveAuthState()
                pendingAccountTeardownRetryReason = .accountSwitchConfirmation(.accountSwitch(
                    previousUserId: cachedUserId,
                    newUserId: user.id
                ))
                accountTeardownError = Self.accountSwitchMessage
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentAuthTransition(hydrationToken) else { return }
                    await self.chatViewModel?.handlePassiveAuthLoss()
                }
                return
            }
            // Update user data BEFORE setting isAuthenticated
            guard isCurrentAuthTransition(hydrationToken) else { return }
            updateUserData(from: user)
            
            // Now set authenticated, which will trigger observers
            self.isAuthenticated = true
            
            // Handle sign in for chat if not already triggered
            if isCurrentAuthTransition(hydrationToken),
               !hasTriggeredSignIn,
               let chatVM = chatViewModel {
                hasTriggeredSignIn = true
                chatVM.handleSignIn()
            }
        }
    }

    private func beginAuthTransition() -> UInt64 {
        isAccountDataAccessReady = false
        ProfileManager.shared.pauseAccountAccess()
        return authHydrationGeneration.advance()
    }

    private func isCurrentAuthTransition(_ token: UInt64) -> Bool {
        authHydrationGeneration.isCurrent(token)
    }

    private var isAccountSwitchConfirmationPending: Bool {
        if case .accountSwitchConfirmation = pendingAccountTeardownRetryReason {
            return true
        }
        return false
    }

    private func clearAccountSwitchFenceIfOwnerReturned(currentClerkUserId: String?) {
        guard case .accountSwitchConfirmation(.accountSwitch(let previousUserId, _)) = pendingAccountTeardownRetryReason,
              currentClerkUserId == previousUserId else { return }
        pendingAccountTeardownRetryReason = nil
        accountTeardownError = nil
    }

    private func resumeAccountDataAccess(for userId: String, hydrationToken: UInt64) {
        guard isCurrentAuthTransition(hydrationToken),
              !isAccountSwitchConfirmationPending,
              clerk?.user?.id == userId,
              localUserId == userId,
              isAuthenticated else { return }
        ProfileManager.shared.resumeAccountAccess()
        isAccountDataAccessReady = true
    }
    
    private func updateUserData(from user: ClerkKit.User) {
        let wasAuthenticated = isAuthenticated
        retainedOwnerUserId = user.id
        
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
        guard !isAccountTeardownInProgress else { return }
        let hydrationToken = beginAuthTransition()
        guard let clerk = self.clerk else {
            guard isCurrentAuthTransition(hydrationToken) else { return }
            isLoading = false
            return
        }

        do {
            if !clerk.isLoaded {
                try await clerk.refreshClient()
                guard isCurrentAuthTransition(hydrationToken) else { return }
            }
        } catch {
            guard isCurrentAuthTransition(hydrationToken) else { return }
            // Network or other error loading Clerk - preserve cached auth state
            // User will remain "authenticated" based on cached state until we can verify
            isSessionUnavailable = isAuthenticated
            isLoading = false
            return
        }

        clearAccountSwitchFenceIfOwnerReturned(currentClerkUserId: clerk.user?.id)
        if isAccountSwitchConfirmationPending {
            await chatViewModel?.handlePassiveAuthLoss()
            guard isCurrentAuthTransition(hydrationToken),
                  isAccountSwitchConfirmationPending else { return }
            isSessionUnavailable = false
            isAuthenticated = false
            hasActiveSubscription = false
            hasTriggeredSignIn = false
            saveAuthState()
            isLoading = false
            return
        }

        let outcome = AuthHydrationOutcome.resolve(
            lastOwnerUserId: retainedOwnerUserId ?? localUserId,
            clerkUserId: clerk.user?.id
        )

        switch outcome {
        case .signedOut, .signedOutPreservingAccount:
            guard isCurrentAuthTransition(hydrationToken) else { return }
            retainedOwnerUserId = localUserId ?? retainedOwnerUserId
            guard isCurrentAuthTransition(hydrationToken) else { return }
            await chatViewModel?.handlePassiveAuthLoss()
            guard isCurrentAuthTransition(hydrationToken) else { return }
            isSessionUnavailable = false
            isAuthenticated = false
            hasActiveSubscription = false
            hasTriggeredSignIn = false
            saveAuthState()
            await RevenueCatManager.shared.logoutUser()
            guard isCurrentAuthTransition(hydrationToken) else { return }
        case .accountSwitch:
            guard let currentUserId = clerk.user?.id,
                  let preservedOwnerUserId = retainedOwnerUserId ?? localUserId else {
                guard isCurrentAuthTransition(hydrationToken) else { return }
                isLoading = false
                return
            }
            retainedOwnerUserId = preservedOwnerUserId
            pendingAccountTeardownRetryReason = .accountSwitchConfirmation(.accountSwitch(
                previousUserId: preservedOwnerUserId,
                newUserId: currentUserId
            ))
            accountTeardownError = Self.accountSwitchMessage
            await chatViewModel?.handlePassiveAuthLoss()
            guard isCurrentAuthTransition(hydrationToken),
                  isAccountSwitchConfirmationPending,
                  retainedOwnerUserId == preservedOwnerUserId else { return }
            isSessionUnavailable = false
            isAuthenticated = false
            hasActiveSubscription = false
            hasTriggeredSignIn = false
            saveAuthState()
        case .authenticated:
            guard let user = clerk.user else {
                guard isCurrentAuthTransition(hydrationToken) else { return }
                isSessionUnavailable = false
                isAuthenticated = false
                hasActiveSubscription = false
                hasTriggeredSignIn = false
                saveAuthState()
                isLoading = false
                return
            }
            isSessionUnavailable = false
            guard isCurrentAuthTransition(hydrationToken) else { return }
            isAuthenticated = true
            updateUserData(from: user)
            await RevenueCatManager.shared.loginUser(user.id)
            guard isCurrentAuthTransition(hydrationToken) else { return }
            resumeAccountDataAccess(for: user.id, hydrationToken: hydrationToken)
            if isCurrentAuthTransition(hydrationToken),
               !hasTriggeredSignIn,
               let chatVM = chatViewModel {
                hasTriggeredSignIn = true
                chatVM.handleSignIn()
            }
        }

        guard isCurrentAuthTransition(hydrationToken) else { return }
        isLoading = false
    }
    
    @discardableResult
    private func clearAuthState(for trigger: AccountTeardownTrigger) async -> Bool {
        guard trigger.isConfirmed(currentClerkUserId: clerk?.user?.id) else {
            return false
        }
        if let accountTeardownTask {
            return await accountTeardownTask.value
        }

        let teardownId = UUID()
        let ownerUserId = trigger.ownerUserId(retainedOwnerUserId: retainedOwnerUserId) ?? localUserId
        isAccountTeardownInProgress = true
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try await self.performAccountTeardown(ownerUserId: ownerUserId)
                self.chatViewModel?.completeAccountTeardown()
                self.accountTeardownError = nil
                self.pendingAccountTeardownRetryReason = nil
                self.retainedOwnerUserId = nil
                return true
            } catch {
                SentrySDK.capture(error: error)
                do {
                    guard trigger.isConfirmed(currentClerkUserId: self.clerk?.user?.id) else {
                        return false
                    }
                    try await self.performAccountTeardown(ownerUserId: ownerUserId)
                    self.chatViewModel?.completeAccountTeardown()
                    self.accountTeardownError = nil
                    self.pendingAccountTeardownRetryReason = nil
                    self.retainedOwnerUserId = nil
                    return true
                } catch {
                    SentrySDK.capture(error: error)
                    self.isLoading = false
                    self.pendingAccountTeardownRetryReason = .teardownFailure(trigger)
                    self.accountTeardownError = "Tinfoil couldn't finish clearing local account data. Account actions remain paused to protect your data. Retry cleanup before continuing."
                    return false
                }
            }
        }
        accountTeardownId = teardownId
        accountTeardownTask = teardownTask
        let didCompleteTeardown = await teardownTask.value
        guard accountTeardownId == teardownId else { return didCompleteTeardown }
        accountTeardownTask = nil
        accountTeardownId = nil
        isAccountTeardownInProgress = false
        return didCompleteTeardown
    }

    func retryAccountTeardown() async {
        guard !isAccountTeardownInProgress else { return }
        let hydrationToken = beginAuthTransition()
        isLoading = true
        guard let retryReason = pendingAccountTeardownRetryReason else {
            isLoading = false
            return
        }
        let trigger = retryReason.trigger
        if retryReason.requiresClerkSignOut {
            isAccountTeardownInProgress = true
            let clerk = self.clerk ?? Clerk.shared
            do {
                if clerk.user != nil {
                    try await clerk.auth.signOut()
                }
            } catch {
                isAccountTeardownInProgress = false
                guard isCurrentAuthTransition(hydrationToken) else { return }
                SentrySDK.capture(error: error)
                accountTeardownError = Self.accountSwitchSignOutFailureMessage
                isLoading = false
                return
            }
            guard isCurrentAuthTransition(hydrationToken) else {
                isAccountTeardownInProgress = false
                return
            }
            guard clerk.user == nil else {
                isAccountTeardownInProgress = false
                accountTeardownError = Self.accountSwitchSignOutFailureMessage
                isLoading = false
                return
            }
        }
        guard isCurrentAuthTransition(hydrationToken) else {
            isAccountTeardownInProgress = false
            return
        }
        guard await clearAuthState(for: trigger) else {
            isAccountTeardownInProgress = false
            return
        }
        guard isCurrentAuthTransition(hydrationToken) else { return }
        await RevenueCatManager.shared.logoutUser()
        guard isCurrentAuthTransition(hydrationToken) else { return }
        if case .accountSwitch = trigger {
            isSessionUnavailable = false
            isAuthenticated = false
            hasActiveSubscription = false
            hasTriggeredSignIn = false
            isLoading = false
        } else {
            await initializeAuthState()
        }
    }

    private func performAccountTeardown(ownerUserId: String?) async throws {
        // Handle chat state BEFORE clearing auth so the view model can still
        // save the current chat (hasChatAccess depends on isAuthenticated).
        if let chatViewModel {
            try await chatViewModel.handleSignOut(ownerUserId: ownerUserId)
        } else {
            try await SharedImportCoordinator.shared.discardAllPending()
            await PasskeyManager.shared.reset()
        }
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
            await chatViewModel.wipeLocalChatsForSignOut(ownerUserId: ownerUserId)
        } else {
            // No chat view model is attached (e.g. sign-out resolved before
            // the UI wired one up); run the same sync teardown handleSignOut
            // performs via clearSyncStatus — fencing in-flight sync,
            // clearing the checkpoint, and resetting the attested client —
            // and only then wipe the files, so a racing sync pass cannot
            // recreate them after the wipe.
            await CloudSyncService.shared.clearSyncStatus(forUser: ownerUserId)
            await Chat.deleteAllChatsFromStorage(userId: ownerUserId)
        }
        EncryptionService.shared.clearKey()
        await DeviceEncryptionService.shared.clearKey()
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
        _ = beginAuthTransition()
        do {
            // If we have a Clerk instance, use it, otherwise fall back to Clerk.shared
            let clerk = self.clerk ?? Clerk.shared
            try await clerk.auth.signOut()
        } catch {
        }
        _ = beginAuthTransition()
        await clearAuthState(for: .explicitSignOut)
    }
    
    /// Fetches subscription status directly from the API
    @discardableResult
    func fetchSubscriptionStatus() async -> Bool {
        guard let clerk = clerk else { return false }
        guard let session = clerk.session else { return false }
        guard let token = try? await session.getToken() ?? session.lastActiveToken?.jwt else { return false }
        
        do {
            let apiURL = "\(Constants.API.baseURL)/api/app/user-metadata"
            
            guard let url = URL(string: apiURL) else { return false }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            
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

                    // If subscription became active, swap the free-tier key for a
                    // subscriber token. Refetch in place rather than clearing first so
                    // in-flight requests keep using the still-valid key until the new
                    // token is stored, instead of briefly sending an empty bearer.
                    if self.hasActiveSubscription && !wasActive {
                        Task {
                            let _ = await SessionTokenManager.shared.fetchFreshSessionToken()
                        }
                    }
                }
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
        _ = beginAuthTransition()
        do {
            guard let clerk = self.clerk else {
                throw NSError(domain: "AuthError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Clerk instance not set"])
            }
            
            guard let user = clerk.user else {
                throw NSError(domain: "AuthError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No user found"])
            }
            
            // Delete the user's account
            let deletedUserId = user.id
            try await user.delete()
            _ = beginAuthTransition()
            
            // Clear local state
            guard await clearAuthState(for: .accountDeletion(deletedUserId: deletedUserId)) else {
                throw NSError(
                    domain: "AuthError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The account was deleted, but local data cleanup did not finish."]
                )
            }
            
        } catch {
            throw error
        }
    }
} 
