//
//  AuthenticationHelpers.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import Clerk

// MARK: - Shared UI Components

/// Button styled for OAuth providers or other auth actions
func authButton(icon: String? = nil, systemIcon: String? = nil, text: String, action: @escaping () -> Void) -> some View {
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
          .frame(width: 24, height: 24)
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

/// User profile image view with fallback to system icon
@ViewBuilder
func userProfileImage(imageURL: URL?) -> some View {
  if let url = imageURL, !url.absoluteString.isEmpty {
    AsyncImage(url: url) { image in
      image
        .resizable()
        .aspectRatio(contentMode: .fill)
    } placeholder: {
      Image(systemName: "person.circle.fill")
        .resizable()
    }
    .frame(width: 80, height: 80)
    .clipShape(Circle())
  } else {
    Image(systemName: "person.circle.fill")
      .resizable()
      .frame(width: 80, height: 80)
      .foregroundColor(.white)
  }
}

// MARK: - Helper Functions

/// Handle authentication errors and provide user-friendly messages
func handleAuthError(_ error: Error) -> String {
  let nsError = error as NSError
  print("Auth error: \(nsError.localizedDescription)")
  
  if nsError.domain == NSURLErrorDomain {
    switch nsError.code {
    case NSURLErrorNotConnectedToInternet:
      return "Please check your internet connection and try again."
    case NSURLErrorTimedOut:
      return "The connection timed out. Please try again."
    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
      return "Unable to connect to authentication service. Please try again later."
    default:
      return "Network error: \(nsError.localizedDescription)"
    }
  } else {
    return nsError.localizedDescription
  }
}

// MARK: - Custom TextField to Avoid Constraint Conflicts

struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var keyboardType: UIKeyboardType
    var isSecure: Bool
    var autocapitalizationType: UITextAutocapitalizationType
    
    init(text: Binding<String>, placeholder: String, keyboardType: UIKeyboardType = .default, isSecure: Bool = false, autocapitalizationType: UITextAutocapitalizationType = .none) {
        self._text = text
        self.placeholder = placeholder
        self.keyboardType = keyboardType
        self.isSecure = isSecure
        self.autocapitalizationType = autocapitalizationType
    }
    
    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.keyboardType = keyboardType
        textField.isSecureTextEntry = isSecure
        textField.backgroundColor = .systemBackground
        textField.layer.cornerRadius = 8
        textField.layer.borderWidth = 1
        textField.layer.borderColor = UIColor.systemGray4.cgColor
        textField.autocapitalizationType = autocapitalizationType
        textField.autocorrectionType = .no
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: textField.frame.height))
        textField.leftViewMode = .always
        textField.clearButtonMode = .whileEditing
        
        // This is crucial to prevent auto layout conflicts
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []
        
        return textField
    }
    
    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.text = text
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }
    
    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        
        init(text: Binding<String>) {
            self._text = text
        }
        
        func textFieldDidChangeSelection(_ textField: UITextField) {
            text = textField.text ?? ""
        }
    }
} 