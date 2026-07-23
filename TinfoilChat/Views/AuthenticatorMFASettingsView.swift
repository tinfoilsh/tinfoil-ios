import ClerkKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct AuthenticatorMFASettingsView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = AuthenticatorMFAViewModel()
    @State private var requestedAction: RequestedAction?
    @State private var isReverificationPresented = false
    @State private var reverificationSucceeded = false
    @State private var isSetupPresented = false
    @State private var shouldPresentBackupCodes = false
    @State private var isDisableConfirmationPresented = false
    @State private var actionTask: Task<Void, Never>?

    private enum SensitiveAction: Equatable {
        case setup
        case disable
    }

    private struct RequestedAction: Equatable {
        let action: SensitiveAction
        let userId: String
        let sessionId: String
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Authenticator App") {
                    Text(model.isEnabled ? "On" : "Off")
                }

                if model.isEnabled {
                    Button("Turn Off Authenticator", role: .destructive) {
                        isDisableConfirmationPresented = true
                    }
                    .disabled(model.isWorking || clerk.user == nil)
                } else {
                    Button("Set Up Authenticator") {
                        request(.setup)
                    }
                    .disabled(model.isWorking || clerk.user == nil)
                }
            } footer: {
                Text("Add an extra layer of security with time-based codes.")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Authenticator App")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.isWorking {
                ProgressView()
            }
        }
        .onAppear {
            syncStatus()
        }
        .onChange(of: clerk.user?.id) { _, _ in
            resetPresentedFlows()
            syncStatus()
        }
        .onChange(of: clerk.session?.id) { _, _ in
            resetPresentedFlows()
            syncStatus()
        }
        .onChange(of: clerk.user?.updatedAt) { _, _ in
            syncStatus()
        }
        .onDisappear {
            actionTask?.cancel()
        }
        .confirmationDialog(
            "Turn off authenticator app?",
            isPresented: $isDisableConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Turn Off", role: .destructive) {
                request(.disable)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Authenticator codes will no longer protect your account.")
        }
        .sheet(isPresented: $isReverificationPresented, onDismiss: handleReverificationDismissal) {
            if let level = model.reverificationLevel {
                MFAReverificationView(level: level) {
                    reverificationSucceeded = true
                    isReverificationPresented = false
                }
            }
        }
        .sheet(isPresented: $isSetupPresented, onDismiss: handleSetupDismissal) {
            if let details = model.setupDetails {
                AuthenticatorMFASetupView(model: model, details: details)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { shouldPresentBackupCodes && !model.backupCodes.isEmpty },
                set: {
                    if !$0 {
                        shouldPresentBackupCodes = false
                        model.dismissBackupCodes()
                    }
                }
            )
        ) {
            BackupCodesView(codes: model.backupCodes) {
                shouldPresentBackupCodes = false
                model.dismissBackupCodes()
            }
            .interactiveDismissDisabled()
        }
    }

    private func syncStatus() {
        model.sync(userId: clerk.user?.id, isEnabled: clerk.user?.totpEnabled == true)
    }

    private func request(_ action: SensitiveAction) {
        guard let userId = clerk.user?.id, let sessionId = clerk.session?.id else { return }
        let request = RequestedAction(action: action, userId: userId, sessionId: sessionId)
        requestedAction = request
        reverificationSucceeded = false
        perform(request)
    }

    private func handleReverificationDismissal() {
        guard reverificationSucceeded, let request = requestedAction else {
            requestedAction = nil
            model.clearReverificationRequest()
            return
        }

        reverificationSucceeded = false
        perform(request)
    }

    private func handleSetupDismissal() {
        model.cancelSetup()
        shouldPresentBackupCodes = !model.backupCodes.isEmpty
    }

    private func perform(_ request: RequestedAction) {
        actionTask?.cancel()
        actionTask = Task {
            guard clerk.user?.id == request.userId,
                  clerk.session?.id == request.sessionId else {
                requestedAction = nil
                return
            }

            let succeeded: Bool
            switch request.action {
            case .setup:
                succeeded = await model.startSetup()
            case .disable:
                succeeded = await model.disable()
            }

            guard !Task.isCancelled,
                  clerk.user?.id == request.userId,
                  clerk.session?.id == request.sessionId else {
                return
            }
            if succeeded {
                requestedAction = nil
                if request.action == .setup {
                    shouldPresentBackupCodes = false
                    isSetupPresented = true
                }
            } else if model.reverificationLevel != nil {
                requestedAction = request
                isReverificationPresented = true
            } else {
                requestedAction = nil
            }
        }
    }

    private func resetPresentedFlows() {
        actionTask?.cancel()
        requestedAction = nil
        isReverificationPresented = false
        isSetupPresented = false
        shouldPresentBackupCodes = false
        model.clearReverificationRequest()
    }
}

private struct AuthenticatorMFASetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AuthenticatorMFAViewModel
    let details: AuthenticatorMFASetupDetails
    @State private var setupKeyCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Scan this code with your authenticator app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    QRCodeImage(value: details.uri)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or enter this setup key manually:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(details.secret)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                copySetupKey()
                            } label: {
                                Image(systemName: setupKeyCopied ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityLabel(setupKeyCopied ? "Setup key copied" : "Copy setup key")
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter the 6-digit code from your authenticator app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextField("Verification code", text: $model.verificationCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.verificationCode) { _, value in
                                let normalized = String(
                                    value
                                        .filter(Constants.Security.asciiDigits.contains)
                                        .prefix(Constants.Security.totpCodeLength)
                                )
                                if normalized != value {
                                    model.verificationCode = normalized
                                }
                            }
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            if await model.verifySetup() {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if model.isWorking {
                                ProgressView()
                            }
                            Text(model.isWorking ? "Verifying..." : "Verify and Turn On")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canVerify)
                }
                .padding()
            }
            .navigationTitle("Set Up Authenticator")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(model.isWorking)
                }
            }
        }
    }

    private func copySetupKey() {
        copySensitiveTextToClipboard(details.secret, copied: $setupKeyCopied)
    }
}

private struct QRCodeImage: View {
    let value: String
    @State private var image: UIImage?

    private static let context = CIContext()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Authenticator setup QR code")
            } else {
                ProgressView()
                    .accessibilityLabel("Generating authenticator setup QR code")
            }
        }
        .task(id: value) {
            image = Self.makeImage(value: value)
        }
    }

    private static func makeImage(value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = Constants.Security.qrCodeCorrectionLevel
        guard let outputImage = filter.outputImage else { return nil }
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct BackupCodesView: View {
    let codes: [String]
    let onDone: () -> Void
    @State private var codesCopied = false
    @State private var shareFile: SharedBackupCodesFile?
    @State private var exportedFileURL: URL?
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(
                        "Save these backup codes somewhere safe. Each code can only be used once if you lose access to your authenticator app."
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(codes, id: \.self) { code in
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        copyCodes()
                    } label: {
                        Label(
                            codesCopied ? "Copied" : "Copy Codes",
                            systemImage: codesCopied ? "checkmark" : "doc.on.doc"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        shareCodes()
                    } label: {
                        Label("Save or Share Text File", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Backup Codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .sheet(item: $shareFile, onDismiss: removeSharedFile) { file in
                ActivityView(activityItems: [file.url])
            }
            .onDisappear(perform: removeSharedFile)
        }
    }

    private func copyCodes() {
        copySensitiveTextToClipboard(codes.joined(separator: "\n"), copied: $codesCopied)
    }

    private func shareCodes() {
        do {
            let url = try BackupCodesFile.write(codes: codes)
            exportedFileURL = url
            shareFile = SharedBackupCodesFile(url: url)
            errorMessage = nil
        } catch {
            errorMessage = "Could not create the backup codes file."
        }
    }

    private func removeSharedFile() {
        if let url = exportedFileURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        exportedFileURL = nil
        shareFile = nil
    }
}

@MainActor
private func copySensitiveTextToClipboard(_ text: String, copied: Binding<Bool>) {
    UIPasteboard.general.setItems(
        [[UIPasteboard.typeAutomatic: text]],
        options: [
            .expirationDate: Date().addingTimeInterval(Constants.CloudSync.clipboardExpirationSeconds)
        ]
    )
    copied.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Share.copyFeedbackDurationSeconds) {
        copied.wrappedValue = false
    }
}

private struct SharedBackupCodesFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MFAReverificationView: View {
    @Environment(Clerk.self) private var clerk
    @Environment(\.dismiss) private var dismiss
    @State private var verification: SessionVerification?
    @State private var input = ""
    @State private var selectedSecondFactor: Factor?
    @State private var preparedFactor: PreparedFactor?
    @State private var isWorking = false
    @State private var errorMessage: String?

    let level: SessionVerification.Level
    let onVerified: () -> Void

    private struct PreparedFactor: Equatable {
        let status: SessionVerification.Status
        let factor: Factor
    }

    private var firstFactor: Factor? {
        preferredFactor(
            from: verification?.supportedFirstFactors ?? [],
            strategies: [.password, .passkey, .emailCode, .phoneCode]
        )
    }

    private var availableSecondFactors: [Factor] {
        verification?.supportedSecondFactors?.filter {
            [.totp, .backupCode, .phoneCode].contains($0.strategy)
        } ?? []
    }

    private var secondFactor: Factor? {
        if let selectedSecondFactor,
           availableSecondFactors.contains(selectedSecondFactor) {
            return selectedSecondFactor
        }
        return preferredFactor(
            from: availableSecondFactors,
            strategies: [.totp, .backupCode, .phoneCode]
        )
    }

    private var activeFactor: Factor? {
        switch verification?.status {
        case .needsFirstFactor:
            firstFactor
        case .needsSecondFactor:
            secondFactor
        default:
            nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(instructions)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if verification?.status == .needsSecondFactor, availableSecondFactors.count > 1 {
                    Picker("Verification method", selection: secondFactorSelection) {
                        ForEach(availableSecondFactors, id: \.self) { factor in
                            Text(label(for: factor)).tag(factor)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isWorking)
                }

                if verification?.status != .complete, activeFactor?.strategy != .passkey {
                    if activeFactor?.strategy == .password {
                        SecureField("Password", text: $input)
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Verification code", text: $input)
                            .keyboardType(
                                activeFactor?.strategy == .backupCode ? .default : .numberPad
                            )
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task {
                        await submit()
                    }
                } label: {
                    HStack {
                        if isWorking {
                            ProgressView()
                        }
                        Text(activeFactor?.strategy == .passkey ? "Verify with Passkey" : "Continue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isWorking
                        || (verification?.status != .complete
                            && activeFactor?.strategy != .passkey
                            && input.isEmpty)
                )

                Spacer()
            }
            .padding()
            .navigationTitle("Confirm It’s You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isWorking)
                }
            }
            .task {
                await start()
            }
            .task(id: selectedSecondFactor) {
                guard selectedSecondFactor != nil else { return }
                await perform {
                    await prepareCurrentFactorIfNeeded()
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var secondFactorSelection: Binding<Factor> {
        Binding(
            get: { secondFactor ?? availableSecondFactors[0] },
            set: {
                guard selectedSecondFactor != $0 else { return }
                selectedSecondFactor = $0
                input = ""
            }
        )
    }

    private var instructions: String {
        if verification?.status == .complete {
            return "You're verified. Tap Continue to finish."
        }
        guard let factor = activeFactor else {
            return isWorking ? "Preparing verification…" : "Verify your identity to continue."
        }
        switch factor.strategy {
        case .password:
            return "Enter your password to continue."
        case .passkey:
            return "Use your passkey to continue."
        case .emailCode:
            return "Enter the code sent to \(factor.safeIdentifier ?? "your email")."
        case .phoneCode:
            return "Enter the code sent to \(factor.safeIdentifier ?? "your phone")."
        case .totp:
            return "Enter the code from your authenticator app."
        case .backupCode:
            return "Enter one of your unused backup codes."
        default:
            return "Verify your identity to continue."
        }
    }

    private func label(for factor: Factor) -> String {
        switch factor.strategy {
        case .totp:
            "Authenticator"
        case .backupCode:
            "Backup Code"
        case .phoneCode:
            factor.safeIdentifier ?? "SMS"
        default:
            "Code"
        }
    }

    private func preferredFactor(from factors: [Factor], strategies: [FactorStrategy]) -> Factor? {
        for strategy in strategies {
            if let factor = factors.first(where: { $0.strategy == strategy }) {
                return factor
            }
        }
        return nil
    }

    private func start() async {
        guard verification == nil else { return }
        guard let session = clerk.session else {
            errorMessage = AuthenticatorMFAError.missingSession.localizedDescription
            return
        }

        await perform {
            let result = try await session.startVerification(level: level)
            try await receive(result)
        }
    }

    private func submit() async {
        if verification?.status == .complete {
            await perform {
                try await finish()
            }
            return
        }
        guard let session = clerk.session, let activeFactor else { return }
        let value = input

        await perform {
            let result: SessionVerification
            switch activeFactor.strategy {
            case .password:
                result = try await session.verifyWithPassword(value)
            case .passkey:
                result = try await session.verifyWithPasskey()
            case .emailCode:
                result = try await session.verifyWithEmailCode(code: value)
            case .phoneCode where verification?.status == .needsFirstFactor:
                result = try await session.verifyWithPhoneCode(code: value)
            case .phoneCode:
                result = try await session.verifyWithMfaPhoneCode(code: value)
            case .totp:
                result = try await session.verifyWithTOTP(code: value)
            case .backupCode:
                result = try await session.verifyWithBackupCode(code: value)
            default:
                throw AuthenticatorMFAError.verificationFailed
            }
            try await receive(result)
        }
    }

    private func receive(_ result: SessionVerification) async throws {
        verification = result
        input = ""

        switch result.status {
        case .complete:
            try await finish()
        case .needsFirstFactor, .needsSecondFactor:
            await prepareCurrentFactorIfNeeded()
        case .unknown:
            errorMessage = Constants.Security.errorMessage
        }
    }

    /// Refreshes the session token so the verified state is picked up, then
    /// reports success. Retryable via the Continue button if the refresh fails.
    private func finish() async throws {
        guard let session = clerk.session else {
            throw AuthenticatorMFAError.missingSession
        }
        _ = try await session.getToken(.init(skipCache: true))
        onVerified()
    }

    private func prepareCurrentFactorIfNeeded() async {
        guard let session = clerk.session, let activeFactor else {
            errorMessage = "No supported verification method is available."
            return
        }
        guard let status = verification?.status else { return }
        let factorToPrepare = PreparedFactor(status: status, factor: activeFactor)
        guard preparedFactor != factorToPrepare else { return }

        do {
            let result: SessionVerification?
            switch (verification?.status, activeFactor.strategy) {
            case (.needsFirstFactor, .emailCode):
                guard let id = activeFactor.emailAddressId else {
                    throw AuthenticatorMFAError.verificationFailed
                }
                result = try await session.sendEmailCode(emailAddressId: id)
            case (.needsFirstFactor, .phoneCode):
                guard let id = activeFactor.phoneNumberId else {
                    throw AuthenticatorMFAError.verificationFailed
                }
                result = try await session.sendPhoneCode(phoneNumberId: id)
            case (.needsSecondFactor, .phoneCode):
                guard let id = activeFactor.phoneNumberId else {
                    throw AuthenticatorMFAError.verificationFailed
                }
                result = try await session.sendMfaPhoneCode(phoneNumberId: id)
            default:
                result = nil
            }
            guard !Task.isCancelled else { return }
            preparedFactor = factorToPrepare
            if let result {
                verification = result
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = AuthenticatorMFAViewModel.message(for: error)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await operation()
        } catch {
            errorMessage = AuthenticatorMFAViewModel.message(for: error)
        }
    }
}
