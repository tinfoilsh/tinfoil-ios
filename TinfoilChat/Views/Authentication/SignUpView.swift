//
//  SignUpView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import SwiftUI
import Clerk
import UIKit

// Preference key to communicate verification state to parent views
struct VerificationModePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

struct SignUpView: View {
    @Environment(Clerk.self) private var clerk
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.colorScheme) private var colorScheme
    @Binding var errorMessage: String?
    @Binding var isLoading: Bool
    @Binding var isSignUp: Bool
    var onDismiss: () -> Void
    
    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var attemptedSubmit = false
    @State private var isVerificationCodeSent = false
    @State private var currentSignUp: SignUp? = nil
    @State private var isVerifyingCode = false
    
    // Expose verification state for parent views to check
    var isInVerificationMode: Bool {
        return isVerificationCodeSent
    }
    
    private var fullNameIsEmpty: Bool {
        return fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var emailIsEmpty: Bool {
        return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var passwordIsEmpty: Bool {
        return password.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 12) {
            if isVerificationCodeSent {
                // Verification code input
                VStack(spacing: 12) {
                    Text("Verify your email")
                        .font(.headline)
                    
                    Text("We've sent a verification code to \(email)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    UIKitTextField(text: $verificationCode, placeholder: "Verification Code", keyboardType: .numberPad)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                        .padding(.bottom, 10)
                        .disabled(isVerifyingCode)
                    
                    Button {
                        guard !isVerifyingCode else { return }
                        
                        Task {
                            await verifyEmail()
                        }
                    } label: {
                        HStack {
                            if isVerifyingCode {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .black : .white))
                                    .padding(.trailing, 8)
                            }
                            Text(isVerifyingCode ? "Verifying..." : "Verify")
                        }
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            colorScheme == .dark ? 
                                (isVerifyingCode ? Color.white.opacity(0.7) : Color.white) : 
                                (isVerifyingCode ? Color.black.opacity(0.7) : Color.black)
                        )
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(isVerifyingCode)
                    
                    Button("Resend verification code") {
                        Task {
                            await resendVerificationCode()
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                    .padding(.top, 8)
                    .disabled(isVerifyingCode || isLoading)
                    
                    // Error message moved to the bottom of verification view
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                    
                    if isLoading && !isVerifyingCode {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
                            .padding(.top, 12)
                    }
                }
            } else {
                // Sign-up form
                UIKitTextField(text: $fullName, placeholder: "Full Name", keyboardType: .default, isSecure: false, autocapitalizationType: .words)
                    .frame(height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(attemptedSubmit && fullNameIsEmpty ? Color.red : Color(UIColor.systemGray4), lineWidth: attemptedSubmit && fullNameIsEmpty ? 2 : 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                
                UIKitTextField(text: $email, placeholder: "Email", keyboardType: .emailAddress)
                    .frame(height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(attemptedSubmit && emailIsEmpty ? Color.red : Color(UIColor.systemGray4), lineWidth: attemptedSubmit && emailIsEmpty ? 2 : 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                
                UIKitTextField(text: $password, placeholder: "Password", isSecure: true)
                    .frame(height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(attemptedSubmit && passwordIsEmpty ? Color.red : Color(UIColor.systemGray4), lineWidth: attemptedSubmit && passwordIsEmpty ? 2 : 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                
                Button(action: {
                    if fullNameIsEmpty || emailIsEmpty || passwordIsEmpty {
                        attemptedSubmit = true
                        errorMessage = "Please fill in all required fields"
                    } else {
                        Task {
                            await signUp(fullName: fullName, email: email, password: password)
                        }
                    }
                }) {
                    Text("Sign Up")
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                
                // Error message and loading indicator moved to the bottom
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
                        .padding(.top, 12)
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .preference(key: VerificationModePreferenceKey.self, value: isVerificationCodeSent)
        .onChange(of: isVerificationCodeSent) { oldValue, newValue in
            // Update preference when verification state changes
            withAnimation {
                // Preference will be automatically updated
            }
        }
    }
    
    private func signUp(fullName: String, email: String, password: String) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            // Split full name into first and last name
            let nameComponents = fullName.components(separatedBy: " ")
            let firstName = nameComponents.first ?? ""
            let lastName = nameComponents.count > 1 ? nameComponents.dropFirst().joined(separator: " ") : ""
            
            // Create sign up with email, password, and name using standard strategy
            let signUp = try await SignUp.create(
                strategy: .standard(
                    emailAddress: email,
                    password: password,
                    firstName: firstName,
                    lastName: lastName
                )
            )
            
            // Store the SignUp instance
            self.currentSignUp = signUp
            
            // Check if email verification is required
            if signUp.unverifiedFields.contains("email_address") {
                // Prepare email verification with email code
                let updatedSignUp = try await signUp.prepareVerification(strategy: .emailCode)
                self.currentSignUp = updatedSignUp
                
                await MainActor.run {
                    isVerificationCodeSent = true
                    isLoading = false
                }
            } else {
                // Email verification not required, proceed with session creation
                if signUp.createdSessionId != nil {
                    // Just reload clerk and initialize auth state
                    try await clerk.load()
                    await authManager.initializeAuthState()
                    
                    await MainActor.run {
                        onDismiss()
                    }
                } else {
                    throw NSError(domain: "ClerkError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create session"])
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Sign-up failed: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
    private func resendVerificationCode() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            guard let signUp = self.currentSignUp else {
                throw NSError(domain: "ClerkError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign-up session expired"])
            }
            
            // Resend verification code
            let updatedSignUp = try await signUp.prepareVerification(strategy: .emailCode)
            self.currentSignUp = updatedSignUp
            
            await MainActor.run {
                errorMessage = "Verification code resent"
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to resend verification code: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
    private func verifyEmail() async {
        await MainActor.run {
            isVerifyingCode = true
            errorMessage = nil
        }
        
        do {
            guard let signUp = self.currentSignUp else {
                throw NSError(domain: "ClerkError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign-up session expired"])
            }
            
            // Attempt verification with the code the user entered
            let verifiedSignUp = try await signUp.attemptVerification(strategy: .emailCode(code: verificationCode))
            self.currentSignUp = verifiedSignUp
            
            // Check if there are still any unverified fields required
            if !verifiedSignUp.unverifiedFields.isEmpty {
                await MainActor.run {
                    errorMessage = "Additional verification required: \(verifiedSignUp.unverifiedFields.joined(separator: ", "))"
                    isVerifyingCode = false
                }
                return
            }
            
            // Check if there are still missing required fields
            if !verifiedSignUp.missingFields.isEmpty {
                await MainActor.run {
                    errorMessage = "Additional information required: \(verifiedSignUp.missingFields.joined(separator: ", "))"
                    isVerifyingCode = false
                }
                return
            }
            
            // Manually complete the sign-up process if needed
            if verifiedSignUp.createdSessionId == nil {
                // Force completion of the sign-up process
                try await clerk.load()
                await authManager.initializeAuthState()
            } else {
                // A session was created, just reload clerk
                try await clerk.load()
                await authManager.initializeAuthState()
            }
            
            await MainActor.run {
                isVerifyingCode = false
                onDismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Verification failed: \(error.localizedDescription)"
                isVerifyingCode = false
            }
        }
    }
}

// Custom button style for better press feedback
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
