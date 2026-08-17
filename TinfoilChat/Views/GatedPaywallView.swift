//
//  GatedPaywallView.swift
//  TinfoilChat
//
//  Created on 07/07/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import RevenueCatUI

func shouldDismissGatedPaywall(
    subscriptionRefreshSucceeded: Bool,
    hasActiveSubscription: Bool
) -> Bool {
    subscriptionRefreshSucceeded && hasActiveSubscription
}

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
    @State private var authenticationCompleted = false

    private enum GateState: Equatable {
        case preparing
        case awaitingAuthentication
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
            case .awaitingAuthentication:
                ProgressView()
                    .controlSize(.large)
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
            if authenticationCompleted {
                authenticationCompleted = false
                gateState = .preparing
            } else {
                dismiss()
            }
        }) {
            AuthenticationView {
                authenticationCompleted = true
                showAuthentication = false
            }
                .environment(Clerk.shared)
                .environmentObject(authManager)
        }
    }

    private func prepare() async {
        if !Clerk.shared.isLoaded {
            do {
                try await Clerk.shared.refreshClient()
            } catch {
                gateState = .failed
                return
            }
        }

        guard Clerk.shared.isLoaded else {
            gateState = .failed
            return
        }

        guard let clerkUserId = Clerk.shared.user?.id else {
            gateState = .awaitingAuthentication
            showAuthentication = true
            return
        }

        let refreshedSubscription = await authManager.fetchSubscriptionStatus()
        if shouldDismissGatedPaywall(
            subscriptionRefreshSucceeded: refreshedSubscription,
            hasActiveSubscription: authManager.hasActiveSubscription
        ) {
            dismiss()
            return
        }
        gateState = await RevenueCatManager.shared.ensureLoggedIn(clerkUserId) ? .ready : .failed
    }
}
