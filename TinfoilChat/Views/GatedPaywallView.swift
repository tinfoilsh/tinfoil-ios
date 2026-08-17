//
//  GatedPaywallView.swift
//  TinfoilChat
//
//  Created on 07/07/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import RevenueCatUI

/// Wraps the RevenueCat paywall and blocks it until the current Clerk user
/// is logged in to RevenueCat. Purchases made while the SDK is still
/// anonymous produce webhooks without a user identifier that the backend
/// rejects, so the paywall must never be reachable in that state.
struct GatedPaywallView: View {
    let onPurchaseCompleted: () -> Void

    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var gateState: GateState = .preparing
    @State private var showAuthentication = false

    private enum GateState: Equatable {
        case preparing
        case signInRequired
        case ready
        case failed
    }

    var body: some View {
        Group {
            switch gateState {
            case .preparing:
                ProgressView()
                    .controlSize(.large)
                    .task { await prepare() }
            case .ready:
                PaywallView(displayCloseButton: true)
                    .onPurchaseCompleted { _ in onPurchaseCompleted() }
            case .signInRequired:
                VStack(spacing: 16) {
                    Text("Sign in to view subscription options and continue chatting.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("Sign In") { showAuthentication = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentPrimary)
                        .foregroundStyle(.black)
                    Button("Close") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
                .padding(32)
            case .failed:
                VStack(spacing: 16) {
                    Text("Unable to load subscription options. Please try again.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("Retry") { gateState = .preparing }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentPrimary)
                        .foregroundStyle(.black)
                    Button("Close") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
                .padding(32)
            }
        }
        .sheet(isPresented: $showAuthentication, onDismiss: {
            gateState = .preparing
        }) {
            AuthenticationView()
                .environment(Clerk.shared)
                .environmentObject(authManager)
        }
        .onChange(of: authManager.localUserId) { _, userId in
            if userId != nil && gateState == .signInRequired {
                gateState = .preparing
            }
        }
    }

    private func prepare() async {
        guard let clerkUserId = authManager.localUserId else {
            gateState = .signInRequired
            return
        }
        gateState = await RevenueCatManager.shared.ensureLoggedIn(clerkUserId) ? .ready : .failed
    }
}
