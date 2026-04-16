//
//  ModularAuthenticationView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import UIKit

struct ModularAuthenticationView: View {
  @Environment(Clerk.self) private var clerk
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var authManager: AuthManager
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var errorMessage: String? = nil
  @State private var isLoading = false
  @State private var isSignUp = false
  @State private var authCheckTask: Task<Void, Never>? = nil
  @State private var isInVerificationMode = false
  @State private var isKeyboardVisible = false
  
  var body: some View {
    NavigationView {
      GeometryReader { geometry in
        ZStack {
          // Background
          (colorScheme == .dark ? Color.backgroundPrimary : Color(UIColor.systemGroupedBackground))
            .edgesIgnoringSafeArea(.all)

          VStack(spacing: 0) {
            // Main content with scroll view to handle keyboard presentation
            VStack(spacing: 0) {
              ScrollView(showsIndicators: false) {
                VStack {
                  authenticationContent
                    .padding(.horizontal)
                }
              }

              // Third-party authentication options at the bottom
              if shouldShowThirdPartyAuth && !isKeyboardVisible {
                Spacer(minLength: 0)

                // Divider with text
                HStack {
                  Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1)

                  Text("or")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)

                  Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1)
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
                .transition(.opacity)

                authButton(
                  icon: "google-icon",
                  text: "Continue with Google",
                  action: { Task { await signInWithOAuth(provider: .google) } }
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.opacity)

                authButton(
                  systemIcon: "apple.logo",
                  text: "Continue with Apple",
                  action: { Task { await signInWithApple() } }
                )
                .padding(.horizontal)
                .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? geometry.safeAreaInsets.bottom : 20)
                .transition(.opacity)
              }
            }
            .frame(maxHeight: .infinity, alignment: .top)
          }
          .contentShape(Rectangle())
          .onTapGesture {
            dismissKeyboard()
          }
        }
        .ignoresSafeArea(.keyboard)
      }
      .background(colorScheme == .dark ? Color.backgroundPrimary : Color(UIColor.systemGroupedBackground))
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Image(colorScheme == .dark ? "logo-white" : "logo-dark")
            .resizable()
            .scaledToFit()
            .frame(height: 22)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {
            dismiss()
          }) {
            Image(systemName: "xmark")
              .font(.system(size: 18, weight: .medium))
          }
          .accessibilityLabel("Close authentication screen")
        }
      }
      .onAppear {
        setupNavigationBarAppearance()
        setupNotifications()
      }
      .onDisappear(perform: cleanupNotifications)
    }
  }
  
  // MARK: - Main Content Components
  
  private var authenticationContent: some View {
    VStack(spacing: 16) {
      authenticationForms
    }
    .onChange(of: clerk.user != nil) { _, isSignedIn in
      if isSignedIn {
        dismiss()
      }
    }
  }
  
  private var authenticationForms: some View {
    VStack(spacing: 4) {
      if isSignUp {
        SignUpView(
          errorMessage: $errorMessage,
          isLoading: $isLoading,
          isSignUp: $isSignUp,
          onDismiss: { DispatchQueue.main.async { self.dismiss() } }
        )
        .onPreferenceChange(VerificationModePreferenceKey.self) { inVerificationMode in
          isInVerificationMode = inVerificationMode
        }.padding(.top, 20)
        
        if !isInVerificationMode {
          Button("Already have an account? Sign In") {
            isSignUp = false
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.top, 4)
        }
      } else {
        SignInView(
          errorMessage: $errorMessage,
          isLoading: $isLoading,
          onDismiss: { DispatchQueue.main.async { self.dismiss() } }
        )
        .onPreferenceChange(VerificationModePreferenceKey.self) { inVerificationMode in
          isInVerificationMode = inVerificationMode
        }
        .padding(.top, 20)
        
        if !isInVerificationMode {
          Button("Don't have an account? Sign Up") {
            isSignUp = true
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.top, 4)
        }
      }
    }
  }
  
  private var thirdPartyAuthOptions: some View {
    EmptyView() // We've moved this directly into the mainContentView
  }
  
  private var shouldShowThirdPartyAuth: Bool {
    clerk.user == nil && !isInVerificationMode
  }

  private func setupNavigationBarAppearance() {
    let appearance = UINavigationBarAppearance()
    if #available(iOS 26, *) {
      appearance.configureWithTransparentBackground()
    } else {
      appearance.configureWithOpaqueBackground()
      appearance.backgroundColor = colorScheme == .dark ? UIColor(Color.backgroundPrimary) : .white
    }
    appearance.shadowColor = .clear

    let tintColor: UIColor = colorScheme == .dark ? .white : .black

    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().compactAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance
    UINavigationBar.appearance().tintColor = tintColor
  }
  
  // MARK: - Authentication Components
  
  @ViewBuilder
  private func authButton(icon: String? = nil, systemIcon: String? = nil, text: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        if let icon = icon {
          Image(icon)
            .resizable()
            .scaledToFit()
            .frame(width: 26, height: 26)
        } else if let systemIcon = systemIcon {
          Image(systemName: systemIcon)
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .padding(2)
        }
        
        Text(text)
          .font(.headline)
          .fontWeight(.medium)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 60)
      .background(Color.white)
      .foregroundColor(.black)
      .cornerRadius(14)
    }
    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
  }
  
  // MARK: - Authentication Methods
  
  private func signInWithOAuth(provider: OAuthProvider) async {
    errorMessage = nil
    
    // Dismiss the modal immediately before starting OAuth flow
    dismiss()
    
    authCheckTask = await OAuthManager.signInWithOAuth(
      provider: provider,
      clerk: clerk,
      authManager: authManager,
      errorCallback: { message in
        errorMessage = message
      },
      loadingStateCallback: { loading in
        isLoading = loading
      }
    )
  }
  
  private func signInWithApple() async {
    errorMessage = nil
    isLoading = true
    
    // Dismiss the modal immediately before starting Apple sign-in flow
    dismiss()
    
    do {
      try await clerk.auth.signInWithApple()

      // Check for successful auth
      try await clerk.refreshClient()
      if clerk.user != nil {
        await authManager.initializeAuthState()
        // Post notification to close sidebar and go to main chat view
        NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
      }
    } catch {
      errorMessage = handleAuthError(error)
    }
    
    isLoading = false
  }
  
  // MARK: - Lifecycle Methods
  
  private func setupNotifications() {
    // Listen for auth completion notification to close this view
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("DismissAuthView"),
      object: nil,
      queue: .main
    ) { _ in
      DispatchQueue.main.async {
        self.dismiss()
      }
    }
    
    // Listen for auth state check notification
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("CheckAuthState"),
      object: nil,
      queue: .main
    ) { [authManager, clerk] _ in
      Task { @MainActor in
        if clerk.user != nil {
          await authManager.initializeAuthState()
          // Post notification to close sidebar and go to main chat view
          NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
          self.dismiss()
        }
      }
    }
    
    // Keyboard appearance notifications
    NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { _ in
      withAnimation(.easeOut(duration: 0.25)) {
        isKeyboardVisible = true
      }
    }
    
    NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillHideNotification,
      object: nil,
      queue: .main
    ) { _ in
      withAnimation(.easeIn(duration: 0.25)) {
        isKeyboardVisible = false
      }
    }
  }
  
  private func cleanupNotifications() {
    // Remove notification observers
    NotificationCenter.default.removeObserver(
      self,
      name: NSNotification.Name("DismissAuthView"),
      object: nil
    )
    
    NotificationCenter.default.removeObserver(
      self,
      name: NSNotification.Name("CheckAuthState"),
      object: nil
    )
    
    // Remove keyboard observers
    NotificationCenter.default.removeObserver(
      self,
      name: UIResponder.keyboardWillShowNotification,
      object: nil
    )
    
    NotificationCenter.default.removeObserver(
      self,
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
    
    // Cancel background task if it's running
    authCheckTask?.cancel()
    authCheckTask = nil
    
    // Ensure auth state is refreshed when this view disappears
    if clerk.user != nil && !authManager.isAuthenticated {
      Task {
        await authManager.initializeAuthState()
      }
    }
    
    // Reset loading state
    isLoading = false
  }
  
  // Function to dismiss keyboard
  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

// MARK: - Preview

#Preview {
  ModularAuthenticationView()
    .environment(Clerk.shared)
    .environmentObject(AuthManager())
} 
