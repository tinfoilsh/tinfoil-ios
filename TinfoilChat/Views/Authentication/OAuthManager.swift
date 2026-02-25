//
//  OAuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit

/// Manager for handling OAuth authentication flows
class OAuthManager {
  /// Initiates the OAuth authentication flow with a specified provider
  /// - Parameters:
  ///   - provider: The OAuth provider to authenticate with (e.g. Google)
  ///   - clerk: The Clerk instance
  ///   - authManager: The app's AuthManager
  ///   - errorCallback: Callback to handle errors
  ///   - loadingStateCallback: Callback to update loading state
  /// - Returns: A Task that can be used to cancel the background auth check
  static func signInWithOAuth(
    provider: OAuthProvider,
    clerk: Clerk,
    authManager: AuthManager,
    errorCallback: @escaping (String) -> Void,
    loadingStateCallback: @escaping (Bool) -> Void
  ) async -> Task<Void, Never>? {
    loadingStateCallback(true)
    
    do {
      try await Task.sleep(nanoseconds: 100_000_000) // Small delay to ensure UI updates
      
      try await clerk.auth.signInWithOAuth(provider: provider)
      
      // Brief delay to ensure redirect completes
      try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
      
      // Start a background task that periodically checks auth state
      let authCheckTask = Task {
        await checkAuthUntilSuccessOrCancelled(clerk: clerk, authManager: authManager)
      }
      
      // Display proper message to user
      errorCallback("Please complete authentication in the browser window.")
      
      return authCheckTask
      
    } catch {
      handleOAuthError(error, errorCallback: errorCallback)
      loadingStateCallback(false)
      return nil
    }
  }
  
  /// A helper method to periodically check authentication status
  private static func checkAuthUntilSuccessOrCancelled(clerk: Clerk, authManager: AuthManager) async {
    // Keep checking until we're authenticated or task is cancelled
    while !Task.isCancelled {
      // Check auth state
      do {
        try await clerk.refreshClient()
        if await clerk.user != nil {
          
          // Update auth state
          await authManager.initializeAuthState()
          
          // Post notification on main thread
          await MainActor.run {
            NotificationCenter.default.post(
              name: NSNotification.Name("DismissAuthView"),
              object: nil
            )
            // Also post notification to close sidebar and go to main chat view
            NotificationCenter.default.post(
              name: NSNotification.Name("AuthenticationCompleted"),
              object: nil
            )
          }
          
          break // Exit the loop once authenticated
        }
      } catch {
      }
      
      do {
        try await Task.sleep(nanoseconds: 500_000_000) // wait 0.5 seconds
      } catch {
        break // Task was cancelled during sleep
      }
    }
  }
  
  private static func handleOAuthError(_ error: Error, errorCallback: @escaping (String) -> Void) {
    let errorMessage = handleAuthError(error)
    errorCallback(errorMessage)
  }
} 
