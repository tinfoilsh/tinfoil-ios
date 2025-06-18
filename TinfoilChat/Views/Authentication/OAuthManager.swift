//
//  OAuthManager.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import SwiftUI
import Clerk

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
      
      // Use SignIn.authenticateWithRedirect for OAuth providers
      try await SignIn.authenticateWithRedirect(strategy: .oauth(provider: provider))
      
      // Keep the loading indicator visible for a bit longer
      // This helps prevent UI flicker during the redirect process
      try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
      
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
        try await clerk.load()
        if await clerk.user != nil {
          
          // Update auth state
          await authManager.initializeAuthState()
          
          // Post notification on main thread
          await MainActor.run {
            NotificationCenter.default.post(
              name: NSNotification.Name("DismissAuthView"),
              object: nil
            )
          }
          
          break // Exit the loop once authenticated
        }
      } catch {
        print("Error checking auth state: \(error)")
      }
      
      do {
        try await Task.sleep(nanoseconds: 2_000_000_000) // wait 2 seconds
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
