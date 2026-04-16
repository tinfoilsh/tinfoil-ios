//
//  SignInView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import UIKit

struct SignInView: View {
  @Environment(Clerk.self) private var clerk
  @EnvironmentObject private var authManager: AuthManager
  @Environment(\.colorScheme) private var colorScheme
  @Binding var errorMessage: String?
  @Binding var isLoading: Bool
  var onDismiss: () -> Void
  
  @State private var email = ""
  @State private var password = ""
  @State private var mfaCode = ""
  @State private var attemptedSubmit = false
  @State private var isEmailFormatInvalid = false
  @State private var showForgotPassword = false
  @State private var needsMfa = false
  @State private var mfaType: SignIn.MfaType = .totp
  @State private var availableMfaTypes: [SignIn.MfaType] = []
  @State private var isVerifyingMfa = false
  
  private var emailIsEmpty: Bool {
    return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  private var passwordIsEmpty: Bool {
    return password.isEmpty
  }
  
  private func isValidEmail(_ email: String) -> Bool {
    let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
    let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegEx)
    return emailPredicate.evaluate(with: email)
  }
  
  var body: some View {
    VStack(spacing: 12) {
      if needsMfa {
        mfaVerificationView
          .transition(.move(edge: .trailing).combined(with: .opacity))
      } else {
        signInFormView
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.25), value: needsMfa)
    .padding(.horizontal, 16)
    .padding(.top, 0)
    .padding(.bottom, 16)
    .contentShape(Rectangle())
    .onTapGesture {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    .sheet(isPresented: $showForgotPassword) {
      ForgotPasswordView(isPresented: $showForgotPassword)
    }
    .preference(key: VerificationModePreferenceKey.self, value: needsMfa)
  }
  
  // MARK: - Sign In Form
  
  private var signInFormView: some View {
    Group {
      UIKitTextField(text: $email, placeholder: "Email", keyboardType: .emailAddress, textContentType: .emailAddress)
        .frame(height: 50)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              attemptedSubmit && emailIsEmpty ? Color.red : 
              isEmailFormatInvalid ? Color.red : 
              Color(UIColor.systemGray4), 
              lineWidth: (attemptedSubmit && emailIsEmpty) || isEmailFormatInvalid ? 2 : 1
            )
        )
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
        .onChange(of: email) { oldValue, newValue in
          if isEmailFormatInvalid {
            isEmailFormatInvalid = !isValidEmail(newValue)
          }
        }
      
      UIKitTextField(text: $password, placeholder: "Password", isSecure: true, textContentType: .password)
        .frame(height: 50)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(attemptedSubmit && passwordIsEmpty ? Color.red : Color(UIColor.systemGray4), lineWidth: attemptedSubmit && passwordIsEmpty ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
      
      Button(action: {
        if emailIsEmpty || passwordIsEmpty {
          attemptedSubmit = true
          errorMessage = "Please fill in all required fields"
        } else if !isValidEmail(email) {
          attemptedSubmit = true
          isEmailFormatInvalid = true
          errorMessage = "Please enter a valid email address"
        } else {
          isEmailFormatInvalid = false
          Task {
            await signIn(email: email, password: password)
          }
        }
      }) {
        Text("Sign In")
          .font(.headline)
          .foregroundColor(colorScheme == .dark ? .black : .white)
          .frame(maxWidth: .infinity)
          .frame(height: 50)
          .background(colorScheme == .dark ? Color.white : Color.black)
          .cornerRadius(8)
          .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
      }
      
      Button(action: {
        showForgotPassword = true
      }) {
        Text("Forgot Password?")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }
      .padding(.top, 8)
      
      if isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
          .padding(.top, 12)
      }
      
      if let errorMessage = errorMessage {
        AuthErrorBanner(message: errorMessage)
          .padding(.top, 8)
      }
    }
  }
  
  // MARK: - MFA Verification
  
  private var mfaVerificationView: some View {
    VStack(spacing: 12) {
      Text("Two-factor authentication")
        .font(.headline)
      
      Text(mfaPromptText)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
      
      UIKitTextField(
        text: $mfaCode,
        placeholder: mfaType == .backupCode ? "Backup Code" : "Verification Code",
        keyboardType: mfaType == .backupCode ? .default : .numberPad,
        textContentType: .oneTimeCode
      )
        .frame(height: 50)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(UIColor.systemGray4), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
        .padding(.bottom, 10)
        .disabled(isVerifyingMfa)
      
      Button {
        guard !isVerifyingMfa else { return }
        Task {
          await verifyMfaCode()
        }
      } label: {
        HStack {
          if isVerifyingMfa {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .black : .white))
              .padding(.trailing, 8)
          }
          Text(isVerifyingMfa ? "Verifying..." : "Verify")
        }
        .font(.headline)
        .foregroundColor(colorScheme == .dark ? .black : .white)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(
          colorScheme == .dark ?
            (isVerifyingMfa ? Color.white.opacity(0.7) : Color.white) :
            (isVerifyingMfa ? Color.black.opacity(0.7) : Color.black)
        )
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
      }
      .buttonStyle(PressableButtonStyle())
      .disabled(isVerifyingMfa)
      
      if hasAlternativeMfaMethod {
        Button("Try another method") {
          switchToAlternativeMfaMethod()
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        .padding(.top, 8)
        .disabled(isVerifyingMfa)
      }
      
      Button("Cancel") {
        needsMfa = false
        mfaCode = ""
        errorMessage = nil
      }
      .font(.subheadline)
      .foregroundColor(.secondary)
      .padding(.top, hasAlternativeMfaMethod ? 0 : 8)
      .disabled(isVerifyingMfa)
      
      if let errorMessage = errorMessage {
        AuthErrorBanner(message: errorMessage)
          .padding(.top, 8)
      }
    }
  }
  
  private var hasAlternativeMfaMethod: Bool {
    return availableMfaTypes.count > 1
  }
  
  private func switchToAlternativeMfaMethod() {
    guard let currentIndex = availableMfaTypes.firstIndex(where: { $0 == mfaType }) else { return }
    let nextIndex = (currentIndex + 1) % availableMfaTypes.count
    let nextType = availableMfaTypes[nextIndex]
    mfaCode = ""
    errorMessage = nil
    mfaType = nextType
    
    if nextType == .phoneCode || nextType == .emailCode {
      Task {
        do {
          if var currentSignIn = clerk.auth.currentSignIn {
            if nextType == .phoneCode {
              currentSignIn = try await currentSignIn.sendMfaPhoneCode()
            } else {
              currentSignIn = try await currentSignIn.sendMfaEmailCode()
            }
          }
        } catch {
          await MainActor.run {
            errorMessage = "Failed to send code: \(error.localizedDescription)"
          }
        }
      }
    }
  }
  
  private var mfaPromptText: String {
    switch mfaType {
    case .totp:
      return "Enter the code from your authenticator app"
    case .phoneCode:
      return "Enter the code sent to your phone"
    case .emailCode:
      return "Enter the code sent to your email"
    case .backupCode:
      return "Enter one of your backup codes"
    }
  }
  
  // MARK: - Actions
  
  private func signIn(email: String, password: String) async {
    await MainActor.run {
      isLoading = true
      errorMessage = nil
    }
    
    do {
      let signIn = try await clerk.auth.signInWithPassword(identifier: email, password: password)
      
      switch signIn.status {
      case .needsSecondFactor:
        let resolvedTypes = resolveAvailableMfaTypes(from: signIn.supportedSecondFactors)
        let preferredType = resolvedTypes.first ?? .totp
        
        if preferredType == .phoneCode {
          if var currentSignIn = clerk.auth.currentSignIn {
            currentSignIn = try await currentSignIn.sendMfaPhoneCode()
          }
        } else if preferredType == .emailCode {
          if var currentSignIn = clerk.auth.currentSignIn {
            currentSignIn = try await currentSignIn.sendMfaEmailCode()
          }
        }
        
        await MainActor.run {
          availableMfaTypes = resolvedTypes
          mfaType = preferredType
          needsMfa = true
          isLoading = false
        }
        
      case .complete:
        try await clerk.refreshClient()
        await authManager.initializeAuthState()
        await MainActor.run {
          NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
          onDismiss()
        }
        
      default:
        await MainActor.run {
          errorMessage = "Sign-in could not be completed. Please try again."
          isLoading = false
        }
      }
    } catch {
      await MainActor.run {
        errorMessage = "Sign-in failed: \(error.localizedDescription)"
        isLoading = false
      }
    }
  }
  
  private func verifyMfaCode() async {
    await MainActor.run {
      isVerifyingMfa = true
      errorMessage = nil
    }
    
    do {
      guard var signIn = clerk.auth.currentSignIn else {
        throw NSError(domain: "ClerkError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign-in session expired. Please try again."])
      }
      
      signIn = try await signIn.verifyMfaCode(mfaCode, type: mfaType)
      
      if signIn.status == .complete {
        try await clerk.refreshClient()
        await authManager.initializeAuthState()
        await MainActor.run {
          isVerifyingMfa = false
          NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
          onDismiss()
        }
      } else {
        await MainActor.run {
          errorMessage = "Verification could not be completed. Please try again."
          isVerifyingMfa = false
        }
      }
    } catch {
      await MainActor.run {
        errorMessage = "Verification failed: \(error.localizedDescription)"
        isVerifyingMfa = false
      }
    }
  }
  
  private func resolveAvailableMfaTypes(from factors: [Factor]?) -> [SignIn.MfaType] {
    guard let factors = factors else { return [.totp] }
    let strategies = Set(factors.map { $0.strategy.rawValue })
    
    let preferenceOrder: [(String, SignIn.MfaType)] = [
      ("totp", .totp),
      ("phone_code", .phoneCode),
      ("email_code", .emailCode),
      ("backup_code", .backupCode),
    ]
    
    let available = preferenceOrder.compactMap { strategies.contains($0.0) ? $0.1 : nil }
    return available.isEmpty ? [.totp] : available
  }
} 
