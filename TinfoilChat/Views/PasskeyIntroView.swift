//
//  PasskeyIntroView.swift
//  TinfoilChat
//
//  Intro modal shown once to existing users who have keys but no passkey backup.
//  Explains that cloud sync is now automatic via passkeys, then triggers Face ID
//  passkey creation on accept.
//

import SwiftUI

struct PasskeyIntroView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Let's go!" — caller triggers the WebAuthn passkey flow.
    var onAccept: () async -> Void

    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)

            // Icons: key <-> passkey
            HStack(spacing: 16) {
                iconCircle(systemName: "key.fill")

                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)

                iconCircle(systemName: "person.badge.key.fill")
            }

            Text("Introducing Passkeys")
                .font(.title2)
                .fontWeight(.bold)

            VStack(spacing: 12) {
                Text("Cloud sync is now automatic\u{2014}your device handles your encryption key for you.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Your chats are still end-to-end encrypted and **only** your Passkey can be used to unlock them.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            Spacer()

            Button(action: handleAccept) {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Let's go!")
                    }
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentPrimary)
                )
            }
            .disabled(isLoading)
            .padding(.horizontal)

            Spacer().frame(height: 24)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isLoading)
    }

    // MARK: - Private

    private func iconCircle(systemName: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 64, height: 64)
            Image(systemName: systemName)
                .font(.system(size: 28))
                .foregroundColor(.primary)
        }
    }

    private func handleAccept() {
        isLoading = true
        Task {
            await onAccept()
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        }
    }
}
