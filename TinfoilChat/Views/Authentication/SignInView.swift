//
//  SignInView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import SwiftUI
import Clerk
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
  @State private var attemptedSubmit = false
  @State private var isEmailFormatInvalid = false
  
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
      UIKitTextField(text: $email, placeholder: "Email", keyboardType: .emailAddress)
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
      
      UIKitTextField(text: $password, placeholder: "Password", isSecure: true)
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
    .padding(.horizontal, 16)
    .padding(.top, 0)
    .padding(.bottom, 16)
    .contentShape(Rectangle())
    .onTapGesture {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
  }
  
  private func signIn(email: String, password: String) async {
    await MainActor.run {
      isLoading = true
      errorMessage = nil
    }
    
    do {
      try await SignIn.create(strategy: .identifier(email, password: password))
      try await clerk.load()
      await authManager.initializeAuthState()
      await MainActor.run {
        // Post notification to close sidebar and go to main chat view
        NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
        onDismiss()
      }
    } catch {
      print("Sign-in error:", error)
      await MainActor.run {
        errorMessage = "Sign-in failed: \(error.localizedDescription)"
        isLoading = false
      }
    }
  }
} 
