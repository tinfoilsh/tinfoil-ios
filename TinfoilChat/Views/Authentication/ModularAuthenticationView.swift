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
  var onAuthenticated: (() -> Void)? = nil

  @Environment(Clerk.self) private var clerk
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var authManager: AuthManager
  @Environment(\.colorScheme) private var colorScheme
  
  @State private var errorMessage: String? = nil
  @State private var isLoading = false
  @State private var isSignUp = false
  @State private var isInVerificationMode = false
  @State private var isKeyboardVisible = false
  @State private var hasCompletedAuthentication = false
  @State private var notificationObservers: [NSObjectProtocol] = []
  @State private var email = ""
  @StateObject private var legalConsent = SignUpLegalConsent()
  
  var body: some View {
    NavigationView {
      GeometryReader { _ in
        ZStack {
          // Background
          Color.settingsBackground(for: colorScheme)
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
                .padding(.bottom)
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
      .background(Color.settingsBackground(for: colorScheme))
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .adaptiveNavigationBarAppearance(
        for: colorScheme,
        background: .settingsBackground(for: colorScheme)
      )
      .tint(colorScheme == .dark ? .white : .black)
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
        setupNotifications()
      }
      .onDisappear(perform: cleanupNotifications)
    }
  }
  
  // MARK: - Main Content Components
  
  private var authenticationContent: some View {
    authenticationForms
      .onChange(of: clerk.user != nil) { _, isSignedIn in
        if isSignedIn && onAuthenticated == nil {
          completeAuthentication()
        }
      }
  }

  private var authenticationForms: some View {
    VStack(spacing: 4) {
      if let signUp = legalConsent.pendingSignUp {
        socialSignUpConsent(signUp)
          .padding(.top, Constants.Legal.completionSpacing)
      } else if isSignUp {
        SignUpView(
          email: $email,
          errorMessage: $errorMessage,
          isLoading: $isLoading,
          legalAccepted: $legalConsent.isAccepted,
          onDismiss: { DispatchQueue.main.async { completeAuthentication() } }
        )
        .onPreferenceChange(VerificationModePreferenceKey.self) { inVerificationMode in
          isInVerificationMode = inVerificationMode
        }.padding(.top, 20)
        
        if !isInVerificationMode {
          Button("Already have an account? Sign In") {
            errorMessage = nil
            legalConsent.reset()
            isSignUp = false
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.top, 4)
        }
      } else {
        SignInView(
          email: $email,
          errorMessage: $errorMessage,
          isLoading: $isLoading,
          onRequestSignUp: {
            errorMessage = nil
            legalConsent.reset()
            isSignUp = true
          },
          onDismiss: { DispatchQueue.main.async { completeAuthentication() } }
        )
        .onPreferenceChange(VerificationModePreferenceKey.self) { inVerificationMode in
          isInVerificationMode = inVerificationMode
        }
        .padding(.top, 20)
        
        if !isInVerificationMode {
          Button("Don't have an account? Sign Up") {
            errorMessage = nil
            legalConsent.reset()
            isSignUp = true
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.top, 4)
        }
      }
    }
    .disabled(isLoading)
  }

  private func socialSignUpConsent(_ signUp: SignUp) -> some View {
    VStack(spacing: Constants.Legal.completionSpacing) {
      Text("Complete your account")
        .font(.headline)

      if signUp.missingFields.contains(.firstName) {
        UIKitTextField(
          text: $legalConsent.firstName,
          placeholder: "First Name",
          autocapitalizationType: .words,
          textContentType: .givenName
        )
        .frame(height: Constants.Legal.completionControlHeight)
      }

      if signUp.missingFields.contains(.lastName) {
        UIKitTextField(
          text: $legalConsent.lastName,
          placeholder: "Last Name",
          autocapitalizationType: .words,
          textContentType: .familyName
        )
        .frame(height: Constants.Legal.completionControlHeight)
      }

      if signUp.missingFields.contains(.legalAccepted) {
        Text("Before creating your account, please review and accept our terms and privacy policy.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        LegalConsentView(isAccepted: $legalConsent.isAccepted)
      }

      Button {
        Task { await completeSocialSignUp() }
      } label: {
        Text("Create Account")
          .font(.headline)
          .foregroundStyle(colorScheme == .dark ? .black : .white)
          .frame(maxWidth: .infinity)
          .frame(height: Constants.Legal.completionControlHeight)
          .background(colorScheme == .dark ? Color.white : Color.black)
          .cornerRadius(Constants.UI.actionButtonCornerRadius)
      }
      .disabled(!legalConsent.canSubmit)

      if isLoading {
        ProgressView()
      }

      if let errorMessage {
        AuthErrorBanner(message: errorMessage)
      }

      Button("Back to Sign In") {
        legalConsent.reset()
        errorMessage = nil
        isInVerificationMode = false
        isSignUp = false
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }
  
  private var thirdPartyAuthOptions: some View {
    EmptyView() // We've moved this directly into the mainContentView
  }
  
  private var shouldShowThirdPartyAuth: Bool {
    clerk.user == nil && !isInVerificationMode && legalConsent.pendingSignUp == nil
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
    .disabled(isLoading || (isSignUp && !legalConsent.isAccepted))
  }
  
  // MARK: - Authentication Methods
  
  @MainActor
  private func signInWithOAuth(provider: OAuthProvider) async {
    guard !isLoading else { return }
    guard !isSignUp || legalConsent.isAccepted else {
      errorMessage = Constants.Legal.consentRequiredMessage
      return
    }
    errorMessage = nil
    isLoading = true
    
    do {
      let result = try await clerk.auth.signInWithOAuth(provider: provider)
      await handleAuthResult(result)
    } catch {
      if !isUserCancellation(error) {
        errorMessage = handleAuthError(error)
      }
    }
    
    isLoading = false
  }
  
  @MainActor
  private func signInWithApple() async {
    guard !isLoading else { return }
    guard !isSignUp || legalConsent.isAccepted else {
      errorMessage = Constants.Legal.consentRequiredMessage
      return
    }
    errorMessage = nil
    isLoading = true
    
    do {
      let result = try await clerk.auth.signInWithApple()
      await handleAuthResult(result)
    } catch {
      if !isUserCancellation(error) {
        errorMessage = handleAuthError(error)
      }
    }
    
    isLoading = false
  }
  
  /// Completes an OAuth or Apple sign-in, keeping the modal open when the
  /// account still needs a second factor so SignInView can prompt for it.
  @MainActor
  private func handleAuthResult(_ result: TransferFlowResult) async {
    if case .signIn = result {
      legalConsent.reset()
    }
    if case .signIn(let signIn) = result, signIn.status == .needsSecondFactor {
      isSignUp = false
      return
    }
    
    do {
      if case .signUp(let signUp) = result {
        let updatedSignUp = try await legalConsent.resolve(signUp)
        guard updatedSignUp.status == .complete else {
          if legalConsent.hasCollectableRequirements {
            return
          }
          if !updatedSignUp.missingFields.isEmpty {
            errorMessage = "Additional information required: \(updatedSignUp.missingFields.map(\.rawValue).joined(separator: ", "))"
          } else if !updatedSignUp.unverifiedFields.isEmpty {
            errorMessage = "Additional verification required: \(updatedSignUp.unverifiedFields.map(\.rawValue).joined(separator: ", "))"
          } else {
            errorMessage = "Sign-up could not be completed. Please start again."
          }
          return
        }
      }
      try await clerk.refreshClient()
    } catch {
      errorMessage = handleAuthError(error)
      return
    }
    
    if clerk.user != nil {
      await authManager.initializeAuthState()
      // Post notification to close sidebar and go to main chat view
      NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
      completeAuthentication()
    } else {
      errorMessage = "Sign-in could not be completed. Please try again."
    }
  }

  @MainActor
  private func completeSocialSignUp() async {
    guard !isLoading, legalConsent.canSubmit,
          let signUp = legalConsent.pendingSignUp else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    await handleAuthResult(.signUp(signUp))
  }
  
  // MARK: - Lifecycle Methods
  
  private func setupNotifications() {
    // Listen for auth completion notification to close this view
    notificationObservers.append(NotificationCenter.default.addObserver(
      forName: NSNotification.Name("DismissAuthView"),
      object: nil,
      queue: .main
    ) { _ in
      DispatchQueue.main.async {
        self.dismiss()
      }
    })
    
    // Listen for auth state check notification
    notificationObservers.append(NotificationCenter.default.addObserver(
      forName: NSNotification.Name("CheckAuthState"),
      object: nil,
      queue: .main
    ) { [authManager, clerk] _ in
      Task { @MainActor in
        if clerk.user != nil {
          await authManager.initializeAuthState()
          // Post notification to close sidebar and go to main chat view
          NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
          completeAuthentication()
        }
      }
    })
    
    // Keyboard appearance notifications
    notificationObservers.append(NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { _ in
      withAnimation(.easeOut(duration: 0.25)) {
        isKeyboardVisible = true
      }
    })
    
    notificationObservers.append(NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillHideNotification,
      object: nil,
      queue: .main
    ) { _ in
      withAnimation(.easeIn(duration: 0.25)) {
        isKeyboardVisible = false
      }
    })
  }
  
  private func cleanupNotifications() {
    // Remove notification observers
    notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    notificationObservers.removeAll()
    
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

  private func completeAuthentication() {
    guard !hasCompletedAuthentication else { return }
    hasCompletedAuthentication = true

    if let onAuthenticated {
      onAuthenticated()
    } else {
      dismiss()
    }
  }
}

// MARK: - Preview

#Preview {
  ModularAuthenticationView()
    .environment(Clerk.shared)
    .environmentObject(AuthManager())
} 
