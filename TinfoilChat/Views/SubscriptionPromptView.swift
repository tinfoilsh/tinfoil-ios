//
//  SubscriptionPromptView.swift
//  TinfoilChat
//
//  Created on 07/11/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI
import RevenueCat

struct SubscriptionPromptView: View {
    let authManager: AuthManager?
    
    @ObservedObject private var revenueCat = RevenueCatManager.shared
    @State private var showAuthView = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    private var isAuthenticated: Bool {
        authManager?.isAuthenticated ?? false
    }
    
    private var hasSubscription: Bool {
        authManager?.hasActiveSubscription ?? false
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Get Premium Models")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            if hasSubscription {
                // Has subscription - show premium benefits
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("Premium Active")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    
                    Text("You have access to all premium models")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                    
                    Button(action: restorePurchases) {
                        Text("Manage Subscription")
                            .font(.system(size: 12))
                            .foregroundColor(.accentPrimary)
                    }
                    .padding(.top, 4)
                }
            } else {
                // No subscription - show subscribe options
                VStack(spacing: 8) {
                    if let package = revenueCat.offerings?.current?.availablePackages.first {
                        Text(package.storeProduct.localizedPriceString)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if !package.storeProduct.localizedDescription.isEmpty {
                            Text(package.storeProduct.localizedDescription)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                        } else {
                            Text("Subscribe to get access to premium models.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                        }
                        
                        if let period = package.storeProduct.subscriptionPeriod {
                            Text(getSubscriptionPeriodText(period))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Subscribe to get access to premium models.")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                    }
                }
                
                if revenueCat.isLoading || revenueCat.isPurchasing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                        .padding(.top, 8)
                } else {
                    VStack(spacing: 8) {
                        Button(action: {
                            if !isAuthenticated {
                                showAuthView = true
                            } else {
                                purchaseSubscription()
                            }
                        }) {
                            Text("Subscribe")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Color.accentPrimary)
                                .cornerRadius(8)
                        }
                        
                        Button(action: restorePurchases) {
                            Text("Restore Purchases")
                                .font(.system(size: 12))
                                .foregroundColor(.accentPrimary)
                        }
                        
                        HStack(spacing: 16) {
                            if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                                Link("Terms of Use", destination: termsURL)
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentPrimary)
                            }
                            
                            if let privacyURL = URL(string: "https://tinfoil.sh/privacy") {
                                Link("Privacy Policy", destination: privacyURL)
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentPrimary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentPrimary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentPrimary.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.top, 8)
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            // Set the Clerk user ID when view appears
            if let userId = authManager?.localUserData?["id"] as? String {
                revenueCat.setClerkUserId(userId)
            }
        }
    }
    
    private func purchaseSubscription() {
        Task {
            do {
                try await revenueCat.purchaseSubscription()
                
                // Force refresh user data to get updated subscription status
                if let authManager = authManager {
                    await authManager.forceRefreshUserData()
                }
            } catch {
                // Don't show error popup if user cancelled the purchase
                if let purchaseError = error as? PurchaseError,
                   case .purchaseCancelled = purchaseError {
                    return
                }
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
    
    private func restorePurchases() {
        Task {
            do {
                try await revenueCat.restorePurchases()
                
                // Force refresh user data to get updated subscription status
                if let authManager = authManager {
                    await authManager.forceRefreshUserData()
                    
                    // Check if subscription is active after refresh
                    if !authManager.hasActiveSubscription {
                        errorMessage = "No purchases found to restore"
                        showError = true
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
    
    private func getSubscriptionPeriodText(_ period: SubscriptionPeriod) -> String {
        let unit = period.unit
        let value = period.value
        
        switch unit {
        case .day:
            return value == 1 ? "Daily subscription" : "\(value)-day subscription"
        case .week:
            return value == 1 ? "Weekly subscription" : "\(value)-week subscription"
        case .month:
            return value == 1 ? "Monthly subscription • Auto-renews" : "\(value)-month subscription • Auto-renews"
        case .year:
            return value == 1 ? "Annual subscription • Auto-renews" : "\(value)-year subscription • Auto-renews"
        @unknown default:
            return "Subscription • Auto-renews"
        }
    }
}
