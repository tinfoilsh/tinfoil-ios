//
//  AuthenticationView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit

// Forward to the modular implementation
struct AuthenticationView: View {
    var onAuthenticated: (() -> Void)? = nil

    var body: some View {
        ModularAuthenticationView(onAuthenticated: onAuthenticated)
    }
}

// MARK: - Preview

#Preview {
  AuthenticationView()
    .environment(Clerk.shared)
    .environmentObject(AuthManager())
}
