//
//  CloudSyncOnboardingView.swift
//  TinfoilChat
//
//  Onboarding modal for setting up cloud sync with encryption key
//

import SwiftUI
import UniformTypeIdentifiers

enum CloudSyncOnboardingStep {
    case intro
    case generateOrRestore
    case keyDisplay
    case restoreKey
}

// MARK: - Onboarding Button Styles

private struct OnboardingButtonModifier: ViewModifier {
    let foreground: Color
    let background: Color

    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(background)
            )
    }
}

private extension View {
    func onboardingPrimaryButton(fill: Color = .accentPrimary) -> some View {
        modifier(OnboardingButtonModifier(foreground: .white, background: fill))
    }

    func onboardingSecondaryButton() -> some View {
        modifier(OnboardingButtonModifier(
            foreground: .primary,
            background: Color(UIColor.secondarySystemBackground)
        ))
    }
}

struct CloudSyncOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var onSetupComplete: ((String) -> Void)?
    var onDismissWithoutSetup: (() -> Void)?

    @State private var currentStep: CloudSyncOnboardingStep = .intro
    @State private var cloudSyncToggle: Bool = true
    @State private var generatedKey: String? = nil
    @State private var inputKey: String = ""
    @State private var isProcessing: Bool = false
    @State private var isCopied: Bool = false
    @State private var keyError: String? = nil
    @State private var showFilePicker: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch currentStep {
                case .intro:
                    introStepView
                case .generateOrRestore:
                    generateOrRestoreStepView
                case .keyDisplay:
                    keyDisplayStepView
                case .restoreKey:
                    restoreKeyStepView
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if currentStep != .intro {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: { handleClose() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(currentStep == .keyDisplay)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "pem") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Step 1: Intro

    private var introStepView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 20)

                // Cloud icon
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                }

                // Step label
                Text("Step 1")
                    .font(.caption)
                    .fontWeight(.medium)
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundColor(.secondary)

                // Title
                Text("Enable Cloud Sync?")
                    .font(.title2)
                    .fontWeight(.bold)

                // Description
                Text("Cloud sync enables encrypted syncing of chats across your devices.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Feature highlights
                VStack(spacing: 16) {
                    featureRow(
                        icon: "lock.fill",
                        title: "End-to-End Encrypted",
                        description: "All chats are encrypted before leaving your device"
                    )

                    featureRow(
                        icon: "key.fill",
                        title: "You Control Your Key",
                        description: "Only you have access to your encryption key"
                    )
                }
                .padding(.horizontal)

                // Toggle row
                HStack {
                    Text("Enable Cloud Sync")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Toggle("", isOn: $cloudSyncToggle)
                        .labelsHidden()
                        .tint(Color.accentPrimary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal)

                // Buttons
                HStack(spacing: 12) {
                    Button(action: { handleMaybeLater() }) {
                        Text("Maybe later")
                            .onboardingSecondaryButton()
                    }

                    Button(action: { handleContinue() }) {
                        Text("Continue")
                            .onboardingPrimaryButton()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Step 2: Generate or Restore

    private var generateOrRestoreStepView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 30)

                // Step label
                Text("Step 2")
                    .font(.caption)
                    .fontWeight(.medium)
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundColor(.secondary)

                // Title
                Text("Encryption Key")
                    .font(.title2)
                    .fontWeight(.bold)

                // Description
                Text("Generate a new personal encryption key or restore an existing one. Your chats will be encrypted and synced with this personal key.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Restore button
                Button(action: {
                    withAnimation { currentStep = .restoreKey }
                }) {
                    Text("Restore Encryption Key")
                        .onboardingSecondaryButton()
                }
                .padding(.horizontal)

                // Back / Generate Key buttons
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation { currentStep = .intro }
                    }) {
                        Text("Back")
                            .onboardingSecondaryButton()
                    }

                    Button(action: { handleGenerateKey() }) {
                        Group {
                            if isProcessing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Generate Key")
                            }
                        }
                        .onboardingPrimaryButton()
                    }
                    .disabled(isProcessing)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Step 3: Key Display (Success)

    private var keyDisplayStepView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 30)

                // Success icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.green)
                }

                // Title
                Text("Success!")
                    .font(.title2)
                    .fontWeight(.bold)

                // Description
                Text("Save this key securely. You'll need it to access your chats on other devices.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Key display
                if let key = generatedKey {
                    HStack {
                        Text(truncateKey(key))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                            .lineLimit(1)

                        Spacer()

                        // Save to Files button
                        Button(action: { saveKeyToFiles() }) {
                            Image(systemName: "arrow.down.doc")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 36, height: 36)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(8)
                        }

                        // Copy button
                        Button(action: { copyKeyToClipboard() }) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.body)
                                .foregroundColor(isCopied ? .white : .primary)
                                .frame(width: 36, height: 36)
                                .background(isCopied ? Color.green : Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                    .padding(.horizontal)
                }

                // Done button
                Button(action: { handleComplete() }) {
                    Text("Done")
                        .onboardingPrimaryButton()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Step 4: Restore Key

    private var restoreKeyStepView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 30)

                // Title
                Text("Restore Encryption Key")
                    .font(.title2)
                    .fontWeight(.bold)

                // Description
                Text("Enter or upload your personal encryption key.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Key input + file import
                HStack(spacing: 8) {
                    SecureField("Enter encryption key", text: $inputKey)
                        .textFieldStyle(.plain)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    keyError != nil ? Color.red.opacity(0.5) : Color.blue.opacity(0.5),
                                    lineWidth: 1
                                )
                        )
                        .onChange(of: inputKey) { _, _ in
                            keyError = nil
                        }

                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "arrow.up.doc")
                            .font(.body)
                            .foregroundColor(.primary)
                            .frame(width: 48, height: 48)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                if let error = keyError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                // Back / Restore Key buttons
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation { currentStep = .generateOrRestore }
                    }) {
                        Text("Back")
                            .onboardingSecondaryButton()
                    }

                    Button(action: { handleRestoreKey() }) {
                        Group {
                            if isProcessing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Restore Key")
                            }
                        }
                        .onboardingPrimaryButton(
                            fill: inputKey.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing
                                ? Color.gray.opacity(0.5)
                                : Color.blue
                        )
                    }
                    .disabled(inputKey.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Shared Components

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func handleMaybeLater() {
        onDismissWithoutSetup?()
        dismiss()
    }

    private func handleContinue() {
        if !cloudSyncToggle {
            cloudSyncToggle = true
        }
        withAnimation { currentStep = .generateOrRestore }
    }

    private func handleClose() {
        if currentStep == .keyDisplay {
            handleComplete()
        } else {
            onDismissWithoutSetup?()
            dismiss()
        }
    }

    private func handleGenerateKey() {
        isProcessing = true
        Task {
            do {
                let newKey = EncryptionService.shared.generateKey()
                try await EncryptionService.shared.setKey(newKey)

                await MainActor.run {
                    generatedKey = newKey
                    isProcessing = false
                    withAnimation { currentStep = .keyDisplay }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    keyError = "Failed to generate encryption key"
                }
            }
        }
    }

    private func handleRestoreKey() {
        let trimmedKey = inputKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }

        isProcessing = true
        Task {
            do {
                try await EncryptionService.shared.setKey(trimmedKey)

                await MainActor.run {
                    SettingsManager.shared.isCloudSyncEnabled = true
                    isProcessing = false
                    onSetupComplete?(trimmedKey)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    keyError = "The encryption key you entered is invalid"
                }
            }
        }
    }

    private func handleComplete() {
        SettingsManager.shared.isCloudSyncEnabled = true
        if let key = generatedKey {
            onSetupComplete?(key)
        }
        dismiss()
    }

    private func copyKeyToClipboard() {
        guard let key = generatedKey else { return }
        UIPasteboard.general.string = key
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }

    private func saveKeyToFiles() {
        guard let key = generatedKey else { return }
        let keyContent = key.replacingOccurrences(of: "key_", with: "")
        let pemContent = """
        -----BEGIN TINFOIL CHAT ENCRYPTION KEY-----
        \(keyContent)
        -----END TINFOIL CHAT ENCRYPTION KEY-----
        """

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let fileName = "tinfoil-chat-key-\(dateString).pem"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try pemContent.data(using: .utf8)?.write(to: tempURL)
            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                // Find the topmost presented view controller
                var topVC = rootViewController
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                activityVC.popoverPresentationController?.sourceView = topVC.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                topVC.present(activityVC, animated: true)
            }
        } catch {
            #if DEBUG
            print("Failed to save key to file: \(error)")
            #endif
        }
    }

    private func truncateKey(_ key: String) -> String {
        if key.count > 20 {
            return String(key.prefix(20)) + "..."
        }
        return key
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                if let extractedKey = extractKeyFromPEM(content) {
                    inputKey = extractedKey
                    keyError = nil
                } else {
                    keyError = "Could not extract encryption key from the PEM file"
                }
            } catch {
                keyError = "Failed to read the PEM file"
            }
        case .failure:
            keyError = "Failed to import file"
        }
    }

    private func extractKeyFromPEM(_ pemContent: String) -> String? {
        let lines = pemContent.components(separatedBy: "\n")
        guard let startIndex = lines.firstIndex(where: { $0.contains("BEGIN TINFOIL CHAT ENCRYPTION KEY") }),
              let endIndex = lines.firstIndex(where: { $0.contains("END TINFOIL CHAT ENCRYPTION KEY") }),
              startIndex < endIndex else {
            return nil
        }

        let keyLines = lines[(startIndex + 1)..<endIndex]
        let keyContent = keyLines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return keyContent.isEmpty ? nil : "key_\(keyContent)"
    }
}
