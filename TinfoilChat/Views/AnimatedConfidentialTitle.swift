//
//  AnimatedConfidentialTitle.swift
//  TinfoilChat
//
//  Created on 19/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI

struct AnimatedConfidentialTitle: View {
    @State private var displayedText = ""
    @State private var currentIndex = 0
    @State private var isLocked = false
    @State private var showLock = false
    
    private let fullText = "Confidential Chat"
    private let typingSpeed = 0.05 // seconds per character
    
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
            startTypingAnimation()
        }
    }
    
    private func startTypingAnimation() {
        Timer.scheduledTimer(withTimeInterval: typingSpeed, repeats: true) { timer in
            if currentIndex < fullText.count {
                let index = fullText.index(fullText.startIndex, offsetBy: currentIndex)
                displayedText.append(fullText[index])
                currentIndex += 1
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