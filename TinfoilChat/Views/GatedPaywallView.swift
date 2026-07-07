//
//  GatedPaywallView.swift
//  TinfoilChat
//
//  Created on 07/07/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI
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

    private enum GateState {
        case preparing
        case ready
        case failed
    }

    var body: some View {
        switch gateState {
        case .preparing:
            ProgressView()
                .controlSize(.large)
                .task { await prepare() }
        case .ready:
            PaywallView(displayCloseButton: true)
                .onPurchaseCompleted { _ in onPurchaseCompleted() }
        case .failed:
            VStack(spacing: 16) {
                Text("Unable to load subscription options. Please check your connection and try again.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Retry") { gateState = .preparing }
                    .buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(32)
        }
    }

    private func prepare() async {
        guard let clerkUserId = authManager.localUserData?["id"] as? String else {
            gateState = .failed
            return
        }
        gateState = await RevenueCatManager.shared.ensureLoggedIn(clerkUserId) ? .ready : .failed
    }
}
