//
//  AuthenticationView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

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
