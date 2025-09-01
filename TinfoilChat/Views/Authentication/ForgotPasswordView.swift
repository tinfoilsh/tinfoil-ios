//
//  ForgotPasswordView.swift
//  TinfoilChat
//
//  Created on 20/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import Clerk

struct ForgotPasswordView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var forceResetView = false
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            // Background
            (colorScheme == .dark ? Color.backgroundPrimary : Color(UIColor.systemGroupedBackground))
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                // Header
                HStack {
                    Spacer()
                    Button(action: { 
                        resetSignInState()
                        isPresented = false 
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(.systemGray))
                    }
                }
                .padding(.horizontal)
                
                VStack(spacing: 8) {
                    Text("Reset Password")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text(subtitleText)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                
                // Content based on sign in status
                Group {
                    if forceResetView {
                        emailInputView
                    } else {
                        switch clerk.client?.signIn?.status {
                        case .needsFirstFactor:
                            verificationCodeView
                            
                        case .needsNewPassword:
                            newPasswordView
                            
                        default:
                            emailInputView
                        }
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top, 20)
        }
        .onDisappear {
            // Clean up when view is dismissed
            resetSignInState()
        }
    }
    
    private var subtitleText: String {
        switch clerk.client?.signIn?.status {
        case .needsFirstFactor:
            return "Enter the verification code sent to your email"
        case .needsNewPassword:
            return "Enter your new password"
        default:
            return "Enter your email to receive a password reset code"
        }
    }
    
    private var emailInputView: some View {
        VStack(spacing: 16) {
            UIKitTextField(text: $email, placeholder: "Email", keyboardType: .emailAddress)
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                .disabled(isLoading)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Button(action: { Task { await sendResetCode() } }) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
                        .scaleEffect(0.8)
                } else {
                    Text("Send Reset Code")
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(email.isEmpty ? Color.gray.opacity(0.3) : (colorScheme == .dark ? Color.white : Color.black))
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            .disabled(email.isEmpty || isLoading)
        }
    }
    
    private var verificationCodeView: some View {
        VStack(spacing: 16) {
            UIKitTextField(text: $code, placeholder: "Verification Code", keyboardType: .numberPad)
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                .disabled(isLoading)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Button(action: { Task { await verifyCode() } }) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
                        .scaleEffect(0.8)
                } else {
                    Text("Verify Code")
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(code.isEmpty ? Color.gray.opacity(0.3) : (colorScheme == .dark ? Color.white : Color.black))
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            .disabled(code.isEmpty || isLoading)
            
            Button(action: { 
                resetSignInState()
                // Force view to show email input again
                forceResetView = true
            }) {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                    Text("Request New Code")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                )
            }
            .padding(.top, 12)
        }
    }
    
    private var newPasswordView: some View {
        VStack(spacing: 16) {
            UIKitTextField(text: $newPassword, placeholder: "New Password", isSecure: true)
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                .disabled(isLoading)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            if let success = successMessage {
                Text(success)
                    .font(.caption)
                    .foregroundColor(.green)
            }
            
            Button(action: { Task { await resetPassword() } }) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
                        .scaleEffect(0.8)
                } else {
                    Text("Reset Password")
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(newPassword.isEmpty ? Color.gray.opacity(0.3) : (colorScheme == .dark ? Color.white : Color.black))
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            .disabled(newPassword.isEmpty || isLoading)
        }
    }
    
    // MARK: - Actions
    
    private func sendResetCode() async {
        errorMessage = nil
        isLoading = true
        forceResetView = false
        
        do {
            try await SignIn.create(strategy: .identifier(email, strategy: .resetPasswordEmailCode()))
        } catch {
            errorMessage = "Failed to send reset code. Please check your email and try again."
        }
        
        isLoading = false
    }
    
    private func verifyCode() async {
        errorMessage = nil
        isLoading = true
        
        do {
            guard let inProgressSignIn = clerk.client?.signIn else {
                errorMessage = "No sign in session found"
                isLoading = false
                return
            }
            
            try await inProgressSignIn.attemptFirstFactor(strategy: .resetPasswordEmailCode(code: code))
        } catch {
            errorMessage = "Invalid verification code. Please try again."
        }
        
        isLoading = false
    }
    
    private func resetPassword() async {
        errorMessage = nil
        isLoading = true
        
        do {
            guard let inProgressSignIn = clerk.client?.signIn else {
                errorMessage = "No sign in session found"
                isLoading = false
                return
            }
            
            try await inProgressSignIn.resetPassword(.init(password: newPassword, signOutOfOtherSessions: true))
            successMessage = "Password reset successfully!"
            
            // Dismiss after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                resetSignInState()
                isPresented = false
            }
        } catch {
            errorMessage = "Failed to reset password. Please ensure it meets the requirements."
        }
        
        isLoading = false
    }
    
    private func resetSignInState() {
        // Reset local state
        email = ""
        code = ""
        newPassword = ""
        errorMessage = nil
        successMessage = nil
        forceResetView = false
    }
}