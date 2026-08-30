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
    var onStartFresh: () async -> PasskeyBackupResult
    /// Cloud sync OFF, dismiss. User can retry from Settings later.
    var onSkip: () -> Void
    /// Enter encryption key manually without passkey.
    var onManualKeyEntry: () -> Void

    @State private var isLoading = false
    @State private var loadingAction: LoadingAction?
    @State private var isStartFreshConfirmationPresented = false
    @State private var failurePresentation: PasskeySetupFailurePresentation?

    private enum LoadingAction {
        case tryAgain
        case startFresh
    }

    private enum Layout {
        static let sheetHeight: CGFloat = 520
        static let failureSheetHeight: CGFloat = 580
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 8)

            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "lock.open")
                    .font(.system(size: 28))
                    .foregroundColor(.primary)
            }
            .accessibilityHidden(true)

            Text("Unlock Your Chats")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)

            Text("Your encrypted chats are stored in the cloud. Authenticate with your passkey to recover your encryption key on this device.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            if let failurePresentation {
                VStack(spacing: 4) {
                    Text(failurePresentation.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(failurePresentation.message)
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                // Try Again — full auth with system UI
                Button(action: handleTryAgain) {
                    Group {
                        if loadingAction == .tryAgain {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("Unlock with Passkey", systemImage: "key.fill")
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
                Button(action: { isStartFreshConfirmationPresented = true }) {
                    Group {
                        if loadingAction == .startFresh {
                            ProgressView()
                                .tint(.primary)
                        } else {
                            Label("Start Fresh with New Key", systemImage: "key.fill"
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

                // Manual key entry — bypass passkey entirely
                Button(action: handleManualKeyEntry) {
                    Label("Enter Key Manually", systemImage: "keyboard")
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
        .presentationDetents([
            .height(failurePresentation == nil ? Layout.sheetHeight : Layout.failureSheetHeight)
        ])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isLoading)
        .alert(
            StartFreshConfirmation.title,
            isPresented: $isStartFreshConfirmationPresented
        ) {
            Button("Go Back", role: .cancel) {}
            Button("Yes, start fresh", role: .destructive) {
                handleStartFresh()
            }
        } message: {
            Text(StartFreshConfirmation.warning)
        }
    }

    // MARK: - Actions

    private func handleTryAgain() {
        isLoading = true
        loadingAction = .tryAgain
        failurePresentation = nil
        Task {
            let success = await onTryAgain()
            await MainActor.run {
                isLoading = false
                loadingAction = nil
                if !success {
                    failurePresentation = PasskeySetupFailurePresentation(.registerFailed)
                }
                if success { dismiss() }
            }
        }
    }

    private func handleStartFresh() {
        isLoading = true
        loadingAction = .startFresh
        Task {
            let result = await onStartFresh()
            await MainActor.run {
                isLoading = false
                loadingAction = nil
                switch result {
                case .success:
                    dismiss()
                case .failure(let failure):
                    failurePresentation = PasskeySetupFailurePresentation(failure)
                }
            }
        }
    }

    private func handleManualKeyEntry() {
        onManualKeyEntry()
        dismiss()
    }

    private func handleSkip() {
        onSkip()
        dismiss()
    }
}
