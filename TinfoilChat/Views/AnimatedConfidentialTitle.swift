//
//  AnimatedConfidentialTitle.swift
//  TinfoilChat
//
//  Created on 19/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import UIKit

struct AnimatedConfidentialTitle: View {
    @State private var displayedText = ""
    @State private var currentIndex = 0
    @State private var isLocked = false
    @State private var showLock = false
    @State private var animationTimer: Timer?
    @ObservedObject private var settings = SettingsManager.shared
    
    private let fullText = "Confidential Chat"
    private let typingSpeed = 0.05 // seconds per character
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    
    var body: some View {
        HStack(spacing: 8) {
            Text(displayedText)
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            
            if showLock {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.title2)
                    .foregroundColor(.primary)
                    .scaleEffect(isLocked ? 1.0 : 0.9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isLocked)
            }
        }
        .onAppear {
            hapticGenerator.prepare()
            startTypingAnimation()
        }
        .onDisappear {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
    
    private func startTypingAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: typingSpeed, repeats: true) { timer in
            if currentIndex < fullText.count {
                let index = fullText.index(fullText.startIndex, offsetBy: currentIndex)
                displayedText.append(fullText[index])
                currentIndex += 1
                
                // Trigger haptic feedback for each character if enabled
                if settings.hapticFeedbackEnabled {
                    hapticGenerator.impactOccurred(intensity: 0.3)
                }
            } else {
                timer.invalidate()
                // Show lock after typing completes
                withAnimation(.easeIn(duration: 0.2)) {
                    showLock = true
                }
                // Lock it after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        isLocked = true
                    }
                    // Trigger haptic feedback for lock if enabled
                    if settings.hapticFeedbackEnabled {
                        let lockHaptic = UINotificationFeedbackGenerator()
                        lockHaptic.notificationOccurred(.success)
                    }
                }
            }
        }
    }
}

// Preview provider for SwiftUI preview
struct AnimatedConfidentialTitle_Previews: PreviewProvider {
    static var previews: some View {
        AnimatedConfidentialTitle()
            .padding()
    }
}