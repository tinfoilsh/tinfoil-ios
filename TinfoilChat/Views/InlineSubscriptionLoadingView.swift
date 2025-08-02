//
//  InlineSubscriptionLoadingView.swift
//  TinfoilChat
//
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI

struct InlineSubscriptionLoadingView: View {
    @ObservedObject var authManager: AuthManager
    @State private var elapsedTime: Int = 0
    @State private var timer: Timer?
    @State private var checkTimer: Timer?
    @State private var dots = ""
    
    let maxWaitTime = 90 // Maximum wait time in seconds
    let checkInterval = 5.0 // Check every 5 seconds
    
    var onSuccess: (() -> Void)?
    var onTimeout: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Activating Premium Access\(dots)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            
            // Progress indicator
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
                .padding(.top, 8)
            
            VStack(spacing: 8) {
                Text("Please wait while we activate your subscription")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("This usually takes 5-60 seconds")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            if elapsedTime > 30 {
                Text("Still working on it... You can continue using free models while we activate premium access.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
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
        .onAppear {
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }
    
    private func startPolling() {
        // Timer for elapsed time and dots animation
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedTime += 1
            
            // Animate dots
            switch dots.count {
            case 0: dots = "."
            case 1: dots = ".."
            case 2: dots = "..."
            default: dots = ""
            }
            
            // Check if we've exceeded max wait time
            if elapsedTime >= maxWaitTime {
                handleTimeout()
            }
        }
        
        // Timer for checking subscription status
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            Task {
                await checkSubscriptionStatus()
            }
        }
        
        // Immediate first check
        Task {
            await checkSubscriptionStatus()
        }
    }
    
    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    private func checkSubscriptionStatus() async {
        // Fetch updated subscription status
        await authManager.fetchSubscriptionStatus()
        
        // Check if subscription is now active
        if authManager.hasActiveSubscription {
            await MainActor.run {
                handleSuccess()
            }
        }
    }
    
    private func handleSuccess() {
        stopPolling()
        
        // Haptic feedback for success
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // Call success handler
        onSuccess?()
    }
    
    private func handleTimeout() {
        stopPolling()
        
        // Call timeout handler
        onTimeout?()
    }
}