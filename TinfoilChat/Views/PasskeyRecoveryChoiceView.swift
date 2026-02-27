//
//  PasskeyRecoveryChoiceView.swift
//  TinfoilChat
//
//  Sheet presented when silent passkey recovery fails on sign-in.
//  Offers explicit choices instead of auto-splitting.
//

import SwiftUI

struct PasskeyRecoveryChoiceView: View {
    @Environment(\.dismiss) private var dismiss

    /// Full auth retry (system UI including "Use a Device Nearby").
    var onTryAgain: () async -> Bool
    /// Generate a new key + create a new passkey (explicit split).
    var onStartFresh: () async -> Bool
    /// Cloud sync OFF, dismiss. User can retry from Settings later.
    var onSkip: () -> Void

    @State private var isLoading = false
    @State private var loadingAction: LoadingAction?

    private enum LoadingAction {
        case tryAgain
        case startFresh
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)

            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "key.slash")
                    .font(.system(size: 28))
                    .foregroundColor(.primary)
            }

            Text("Passkey Not Found")
                .font(.title2)
                .fontWeight(.bold)

            Text("We couldn't find a matching passkey on this device. Your passkey might be in iCloud Keychain or a password manager that hasn't synced yet.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                // Try Again — full auth with system UI
                Button(action: handleTryAgain) {
                    Group {
                        if loadingAction == .tryAgain {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("Try Again", systemImage: "arrow.clockwise")
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

                // Start Fresh — new key + new passkey
                Button(action: handleStartFresh) {
                    Group {
                        if loadingAction == .startFresh {
                            ProgressView()
                                .tint(.primary)
                        } else {
                            Label("Start Fresh with New Key", systemImage: "plus.key.fill"
                            )
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .disabled(isLoading)

                // Skip — cloud sync off
                Button(action: handleSkip) {
                    Text("Skip for Now")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .disabled(isLoading)
            }
            .padding(.horizontal)

            Spacer().frame(height: 24)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isLoading)
    }

    // MARK: - Actions

    private func handleTryAgain() {
        isLoading = true
        loadingAction = .tryAgain
        Task {
            let success = await onTryAgain()
            await MainActor.run {
                isLoading = false
                loadingAction = nil
                if success { dismiss() }
            }
        }
    }

    private func handleStartFresh() {
        isLoading = true
        loadingAction = .startFresh
        Task {
            let success = await onStartFresh()
            await MainActor.run {
                isLoading = false
                loadingAction = nil
                if success { dismiss() }
            }
        }
    }

    private func handleSkip() {
        onSkip()
        dismiss()
    }
}
