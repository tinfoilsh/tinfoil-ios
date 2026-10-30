//
//  AuthenticationHelpers.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import AuthenticationServices
import SwiftUI
import ClerkKit

// MARK: - Error Banner

struct AuthErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)

            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Helper Functions

/// Whether the error represents the user backing out of an authentication
/// prompt (browser sheet or Apple sign-in), which should not surface an error.
func isUserCancellation(_ error: Error) -> Bool {
  if error is CancellationError {
    return true
  }
  let nsError = error as NSError
  if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
     nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
    return true
  }
  if nsError.domain == ASAuthorizationError.errorDomain,
     nsError.code == ASAuthorizationError.canceled.rawValue {
    return true
  }
  return false
}

/// Handle authentication errors and provide user-friendly messages
func handleAuthError(_ error: Error) -> String {
  let nsError = error as NSError
  
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

final class AdaptiveBorderTextField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureBorderAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureBorderAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBorderColor()
    }

    private func configureBorderAppearance() {
        updateBorderColor()
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self,
            UITraitUserInterfaceLevel.self
        ]) { (textField: AdaptiveBorderTextField, _: UITraitCollection) in
            textField.updateBorderColor()
        }
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.systemGray4.resolvedColor(with: traitCollection).cgColor
    }
}

struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var keyboardType: UIKeyboardType
    var isSecure: Bool
    var autocapitalizationType: UITextAutocapitalizationType
    var textContentType: UITextContentType?

    init(text: Binding<String>, placeholder: String, keyboardType: UIKeyboardType = .default, isSecure: Bool = false, autocapitalizationType: UITextAutocapitalizationType = .none, textContentType: UITextContentType? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.keyboardType = keyboardType
        self.isSecure = isSecure
        self.autocapitalizationType = autocapitalizationType
        self.textContentType = textContentType
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = AdaptiveBorderTextField()
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.accessibilityLabel = placeholder
        textField.keyboardType = keyboardType
        textField.isSecureTextEntry = isSecure
        textField.textColor = .label
        textField.backgroundColor = .systemBackground
        textField.layer.cornerRadius = 8
        textField.layer.borderWidth = 1
        textField.autocapitalizationType = autocapitalizationType
        textField.autocorrectionType = .no
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: textField.frame.height))
        textField.leftViewMode = .always
        textField.clearButtonMode = .whileEditing
        textField.textContentType = textContentType

        return textField
    }
    
    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
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
