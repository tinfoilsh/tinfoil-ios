//
//  RevenueCatManager.swift
//  TinfoilChat
//
//  Created on 07/11/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI
import RevenueCat
import Clerk

// MARK: - Purchase Error Types
enum PurchaseError: LocalizedError {
    case noAvailablePackages
    case purchaseCancelled
    case purchaseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noAvailablePackages:
            return "No subscription packages available"
        case .purchaseCancelled:
            return "Purchase was cancelled"
        case .purchaseFailed(let message):
            return "Purchase failed: \(message)"
        }
    }
}

// MARK: - RevenueCat Manager
@MainActor
class RevenueCatManager: ObservableObject {
    @Published var customerInfo: CustomerInfo? {
        didSet {
            subscriptionActive = customerInfo?.entitlements["premium_chat"]?.isActive == true
        }
    }
    @Published var offerings: Offerings?
    @Published var subscriptionActive: Bool = false
    @Published var isLoading = false
    @Published var isPurchasing = false
    
    static let shared = RevenueCatManager()
    
    private init() {}
    
    /// Configure RevenueCat with API key
    func configure(apiKey: String) {
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: apiKey)
        
        // Listen to changes in the customerInfo object using an AsyncStream
        Task {
            for await newCustomerInfo in Purchases.shared.customerInfoStream {
                await MainActor.run { customerInfo = newCustomerInfo }
            }
        }
        
        // Load offerings immediately after configuration
        Task {
            await fetchOfferings()
        }
    }
    
    /// Set the Clerk user ID as a subscriber attribute
    /// This is only visible in webhooks, not to other users
    func setClerkUserId(_ clerkUserId: String) {
        // Set as subscriber attribute for webhook processing
        Purchases.shared.attribution.setAttributes([
            "clerk_user_id": clerkUserId
        ])
    }
    
    /// Fetch available offerings
    func fetchOfferings() async {
        isLoading = true
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            print("Failed to fetch offerings: \(error)")
        }
        isLoading = false
    }
    
    /// Purchase a package
    func purchase(_ package: Package) async throws {
        isPurchasing = true
        defer { isPurchasing = false }
        
        do {
            let (_, customerInfo, userCancelled) = try await Purchases.shared.purchase(package: package)
            
            if userCancelled {
                throw PurchaseError.purchaseCancelled
            }
            
            self.customerInfo = customerInfo
            
            // Give webhook a moment to process
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
        } catch {
            throw PurchaseError.purchaseFailed(error.localizedDescription)
        }
    }
    
    /// Purchase the chat subscription
    func purchaseSubscription() async throws {
        // Get offerings if not loaded
        if offerings == nil {
            await fetchOfferings()
        }
        
        // Get the default offering or a specific one
        guard let offering = offerings?.current,
              let package = offering.availablePackages.first else {
            throw PurchaseError.noAvailablePackages
        }
        
        try await purchase(package)
    }
    
    /// Restore purchases
    func restorePurchases() async throws {
        isPurchasing = true
        defer { isPurchasing = false }
        
        let customerInfo = try await Purchases.shared.restorePurchases()
        self.customerInfo = customerInfo
        
        // Give webhook a moment to process
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    
}
