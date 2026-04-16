//
//  CloudSyncOnboardingView.swift
//  TinfoilChat
//
//  Onboarding modal for setting up cloud sync with encryption key
//

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

enum CloudSyncOnboardingStep {
    case intro
    case generateOrRestore
    case keyDisplay
    case restoreKey
}

// MARK: - Onboarding Button Styles

private struct OnboardingButtonModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(isDisabled
                ? .secondary
                : (colorScheme == .dark ? .black : .white))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isDisabled
                        ? Color.secondary.opacity(0.2)
                        : (colorScheme == .dark ? Color.white : Color.black))
            )
    }
}

private struct OnboardingSecondaryButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
    }
}

private extension View {
    func onboardingPrimaryButton(isDisabled: Bool = false) -> some View {
        modifier(OnboardingButtonModifier(isDisabled: isDisabled))
    }

    func onboardingSecondaryButton() -> some View {
        modifier(OnboardingSecondaryButtonModifier())
    }
}

struct CloudSyncOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var mode: CloudSyncOnboardingMode = .setup
    var onSetupComplete: ((String, CloudKeyActivationMode) async -> String?)?
    var onDismissWithoutSetup: (() -> Void)?

    @State private var currentStep: CloudSyncOnboardingStep = .intro
    @State private var cloudSyncToggle: Bool = true
    @State private var generatedKey: String? = nil
    @State private var generatedKeyMode: CloudKeyActivationMode = .recoverExisting
    @State private var inputKey: String = ""
    @State private var isProcessing: Bool = false
    @State private var isCopied: Bool = false
    @State private var keyError: String? = nil
    @State private var showFilePicker: Bool = false
    @State private var showQRScanner: Bool = false
    @State private var direction: Edge = .trailing
    @State private var showFeatures: Bool = false
    @State private var animateIcon: Bool = false

    private var currentPageIndex: Int {
        switch currentStep {
        case .intro: return 0
        case .generateOrRestore: return 1
        case .keyDisplay, .restoreKey: return 2
        }
    }

    private let totalPages = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Close button
                HStack {
                    Button(action: { handleClose() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 30)
                            .background(
                                Circle()
                                    .fill(Color(UIColor.secondarySystemBackground))
                            )
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // Page dot indicators
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPageIndex ? Color.accentPrimary : Color.secondary.opacity(0.3))
                            .frame(width: index == currentPageIndex ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPageIndex)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 8)

                ZStack {
                    switch currentStep {
                    case .intro:
                        introStepView
                            .transition(.asymmetric(
                                insertion: .move(edge: direction).combined(with: .opacity),
                                removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)
                            ))
                    case .generateOrRestore:
                        generateOrRestoreStepView
                            .transition(.asymmetric(
                                insertion: .move(edge: direction).combined(with: .opacity),
                                removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)
                            ))
                    case .keyDisplay:
                        keyDisplayStepView
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    case .restoreKey:
                        restoreKeyStepView
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
            }
            .background(backgroundGradient)
            .navigationBarHidden(true)
        }
        .interactiveDismissDisabled(currentStep == .keyDisplay && keyError == nil)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "pem") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerView(isPresented: $showQRScanner) { scannedKey in
                showQRScanner = false
                inputKey = scannedKey
                keyError = nil
            }
        }
    }

    // MARK: - Step 1: Intro

    private var introStepView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                // Cloud icon
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(animateIcon ? 1.0 : 0.8)
                        .opacity(animateIcon ? 1.0 : 0)

                    Circle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 88, height: 88)

                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 36))
                        .foregroundColor(.primary)
                }
                .onAppear {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.2)) {
                        animateIcon = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showFeatures = true
                    }
                }

                // Title
                Text("Enable Cloud Sync?")
                    .font(.title)
                    .fontWeight(.bold)

                // Description
                Text("Cloud sync enables encrypted syncing of chats across your devices.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Feature highlights
                VStack(spacing: 12) {
                    ForEach(Array([
                        ("lock.fill", "End-to-End Encrypted", "All chats are encrypted before leaving your device"),
                        ("key.fill", "You Control Your Key", "Only you have access to your encryption key"),
                    ].enumerated()), id: \.offset) { index, feature in
                        featureRow(
                            icon: feature.0,
                            title: feature.1,
                            description: feature.2
                        )
                        .opacity(showFeatures ? 1 : 0)
                        .offset(y: showFeatures ? 0 : 20)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.8)
                                .delay(Double(index) * 0.1),
                            value: showFeatures
                        )
                    }
                }
                .padding(.horizontal, 24)

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
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .padding(.horizontal, 24)

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
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Step 2: Generate or Restore

    private var generateOrRestoreStepView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                // Key icon
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
                        .frame(width: 120, height: 120)

                    Circle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 88, height: 88)

                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.primary)
                }

                // Title
                Text("Encryption Key")
                    .font(.title)
                    .fontWeight(.bold)

                // Description
                Text(
                    mode == .recovery
                        ? "Restore your existing encryption key to unlock cloud data, or explicitly start fresh with a new key."
                        : "Generate a new personal encryption key or restore an existing one. Your chats will be encrypted and synced with this personal key."
                )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Restore button
                Button(action: {
                    direction = .trailing
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        currentStep = .restoreKey
                    }
                }) {
                    Text("Restore Encryption Key")
                        .onboardingSecondaryButton()
                }
                .padding(.horizontal, 24)

                // Back / Generate Key buttons
                HStack(spacing: 12) {
                    Button(action: {
                        direction = .leading
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentStep = .intro
                        }
                    }) {
                        Text("Back")
                            .onboardingSecondaryButton()
                    }

                    Button(action: { handleGenerateKey() }) {
                        Group {
                            if isProcessing {
                                ProgressView()
                                    .tint(colorScheme == .dark ? .black : .white)
                            } else {
                                Text(mode == .recovery ? "Start Fresh" : "Generate Key")
                            }
                        }
                        .onboardingPrimaryButton()
                    }
                    .disabled(isProcessing)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Step 3: Key Display (Success)

    private var keyDisplayStepView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 30)

                // Success icon
                ZStack {
                    Circle()
                        .strokeBorder(Color.green.opacity(0.2), lineWidth: 2)
                        .frame(width: 120, height: 120)

                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 88, height: 88)

                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.green)
                }

                // Title
                Text("Success!")
                    .font(.title)
                    .fontWeight(.bold)

                // Description
                Text(
                    generatedKeyMode == .explicitStartFresh
                        ? "Save this key securely. Using it will start a new encrypted cloud history on this device."
                        : "Save this key securely. You'll need it to access your chats on other devices."
                )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Key display
                if let key = generatedKey {
                    HStack {
                        Text(truncateKey(key))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
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
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                    .padding(.horizontal, 24)
                }

                // Done button
                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button(action: { handleComplete() }) {
                    Text("Done")
                        .onboardingPrimaryButton()
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Step 4: Restore Key

    private var restoreKeyStepView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 30)

                // Title
                Text("Restore Encryption Key")
                    .font(.title)
                    .fontWeight(.bold)

                // Description
                Text("Enter or upload your personal encryption key.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Key input + file import
                HStack(spacing: 8) {
                    SecureField("Enter encryption key", text: $inputKey)
                        .textFieldStyle(.plain)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(UIColor.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    keyError != nil ? Color.red.opacity(0.5) : Color.primary.opacity(0.15),
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
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 24)

                if let error = keyError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 24)
                }

                // OR divider
                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("OR")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal, 24)

                // Scan QR Code button
                Button(action: {
                    requestCameraPermission { granted in
                        if granted {
                            showQRScanner = true
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title3)
                        Text("Scan QR Code")
                            .fontWeight(.semibold)
                    }
                    .onboardingSecondaryButton()
                }
                .padding(.horizontal, 24)

                // Back / Restore Key buttons
                let isRestoreDisabled = inputKey.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing
                HStack(spacing: 12) {
                    Button(action: {
                        direction = .leading
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentStep = .generateOrRestore
                        }
                    }) {
                        Text("Back")
                            .onboardingSecondaryButton()
                    }

                    Button(action: { handleRestoreKey() }) {
                        Group {
                            if isProcessing {
                                ProgressView()
                                    .tint(colorScheme == .dark ? .black : .white)
                            } else {
                                Text("Restore Key")
                            }
                        }
                        .onboardingPrimaryButton(isDisabled: isRestoreDisabled)
                    }
                    .disabled(isRestoreDisabled)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer().frame(height: 20)
            }
        }
    }

    // MARK: - Shared Components

    private var backgroundGradient: some View {
        Group {
            if colorScheme == .dark {
                Color.backgroundPrimary
            } else {
                Color.white
            }
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.primary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        direction = .trailing
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            currentStep = .generateOrRestore
        }
    }

    private func handleClose() {
        if currentStep == .keyDisplay && keyError == nil {
            handleComplete()
        } else {
            onDismissWithoutSetup?()
            dismiss()
        }
    }

    private func handleGenerateKey() {
        isProcessing = true
        Task {
            let newKey = EncryptionService.shared.generateKey()

            await MainActor.run {
                generatedKey = newKey
                generatedKeyMode = mode == .recovery ? .explicitStartFresh : .recoverExisting
                keyError = nil
                isProcessing = false
                direction = .trailing
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    currentStep = .keyDisplay
                }
            }
        }
    }

    private func handleRestoreKey() {
        let trimmedKey = inputKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }

        isProcessing = true
        Task {
            await completeSetup(with: trimmedKey, activationMode: .recoverExisting)
        }
    }

    private func handleComplete() {
        guard let key = generatedKey else { return }
        isProcessing = true
        Task {
            await completeSetup(with: key, activationMode: generatedKeyMode)
        }
    }

    private func completeSetup(with key: String, activationMode: CloudKeyActivationMode) async {
        let errorMessage = await onSetupComplete?(key, activationMode) ?? nil

        await MainActor.run {
            isProcessing = false
            if let errorMessage {
                keyError = errorMessage
                return
            }

            SettingsManager.shared.isCloudSyncEnabled = true
            dismiss()
        }
    }

    private func copyKeyToClipboard() {
        guard let key = generatedKey else { return }
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: key]],
            options: [
                .expirationDate: Date().addingTimeInterval(Constants.CloudSync.clipboardExpirationSeconds)
            ]
        )
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
                activityVC.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: tempURL)
                }
                topVC.present(activityVC, animated: true)
            } else {
                try? FileManager.default.removeItem(at: tempURL)
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

    private func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            let alert = UIAlertController(
                title: "Camera Access Required",
                message: "Please enable camera access in Settings to scan QR codes.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                var topVC = rootViewController
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                topVC.present(alert, animated: true)
            }
            completion(false)
        @unknown default:
            completion(false)
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
