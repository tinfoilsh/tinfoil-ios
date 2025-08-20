//
//  AuthenticationView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import Clerk

// Forward to the modular implementation
struct AuthenticationView: View {
    var body: some View {
        ModularAuthenticationView()
    }
}

// MARK: - Preview

#Preview {
  AuthenticationView()
    .environment(Clerk.shared)
    .environmentObject(AuthManager())
}
