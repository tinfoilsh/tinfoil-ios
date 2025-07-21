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
            
            if !hasSubscription {
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
                        
                        HStack(spacing: 4) {
                            Button(action: restorePurchases) {
                                Text("Restore Purchases")
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentPrimary)
                            }
                            
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            
                            if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                                Link("Terms of Use", destination: termsURL)
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentPrimary)
                            }
                            
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            
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
            // Clerk user ID will be set when purchase is initiated
        }
    }
    
    private func purchaseSubscription() {
        Task {
            do {
                // Get Clerk user ID and set it right before purchase
                let clerkUserId = authManager?.localUserData?["id"] as? String
                try await revenueCat.purchaseSubscription(clerkUserId: clerkUserId)
                
                // Wait a moment for webhook to process
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                // Try to refresh user data up to 3 times to get updated subscription status
                if let authManager = authManager {
                    var subscriptionActive = false
                    
                    for attempt in 1...3 {
                        await authManager.forceRefreshUserData()
                        
                        // Check if subscription is now active
                        if authManager.hasActiveSubscription {
                            subscriptionActive = true
                            break
                        }
                        
                        // Wait before next attempt (except on last attempt)
                        if attempt < 3 {
                            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                        }
                    }
                    
                    if !subscriptionActive {
                        errorMessage = "Subscription purchased successfully, but it may take a moment to activate. Please restart the app if needed."
                        showError = true
                    }
                }
            } catch {
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
            return value == 1 ? "Auto-renews daily unless canceled" : "Auto-renews every \(value) days unless canceled"
        case .week:
            return value == 1 ? "Auto-renews weekly unless canceled" : "Auto-renews every \(value) weeks unless canceled"
        case .month:
            return value == 1 ? "Auto-renews monthly unless canceled" : "Auto-renews every \(value) months unless canceled"
        case .year:
            return value == 1 ? "Auto-renews annually unless canceled" : "Auto-renews every \(value) years unless canceled"
        @unknown default:
            return "Auto-renews unless canceled"
        }
    }
}
