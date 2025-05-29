//
//  VerifierView.swift
//  TinfoilChat
//
//  Created on 2/25/25.
//

import SwiftUI
import TinfoilAI

/// Configuration for verification steps
private struct VerificationStepConfig {
    struct Step {
        let key: String
        let description: String
        
        func title(for status: VerifierStatus) -> String {
            switch status {
            case .loading: return loadingTitle
            case .success: return successTitle
            default: return defaultTitle
            }
        }
        
        let defaultTitle: String
        let loadingTitle: String
        let successTitle: String
    }
    
    static let codeIntegrity = Step(
        key: "CODE_INTEGRITY",
        description: "Verifies that the source code published on GitHub was correctly built and the resulting binary was published to the Sigstore transparency log.",
        defaultTitle: "Code Integrity Check",
        loadingTitle: "Checking Code Integrity...",
        successTitle: "Code Integrity Verified"
    )
    
    static let remoteAttestation = Step(
        key: "REMOTE_ATTESTATION",
        description: "Verifies that the remote secure enclave environment is set up correctly and receive the digest of the binary running in the enclave.",
        defaultTitle: "Enclave Runtime Attestation",
        loadingTitle: "Fetching Attestation Report...",
        successTitle: "Enclave Runtime Checked"
    )
    
    static let codeConsistency = Step(
        key: "CODE_CONSISTENCY",
        description: "Verifies that the binary built from the source code matches the binary running in the enclave by comparing digests from the enclave and the transparency log.",
        defaultTitle: "Consistency Check",
        loadingTitle: "Checking Binaries...",
        successTitle: "Binaries Match"
    )
    
    static func step(for key: String) -> Step {
        switch key {
        case "CODE_INTEGRITY": return codeIntegrity
        case "REMOTE_ATTESTATION": return remoteAttestation
        case "CODE_CONSISTENCY": return codeConsistency
        default: fatalError("Unknown step key: \(key)")
        }
    }
} 

/// Pure SwiftUI implementation of the Verifier view
struct VerifierView: View {
    
    /// The overall verification state (code, runtime, security).
    @State private var verificationState: VerificationState
    
    /// Whether we are verifying right now.
    @State private var isVerifying: Bool = false
    
    /// Access to the chat view model for updating verification status
    @EnvironmentObject var chatViewModel: ChatViewModel
    
    // Color scheme for adapting to dark/light mode
    @Environment(\.colorScheme) private var colorScheme
    
    init(initialVerificationState: Bool? = nil, initialError: String? = nil) {
        // Create an initial verification state based on chatViewModel's state
        let initialState: VerificationState
        
        if let isVerified = initialVerificationState {
            if isVerified {
                initialState = VerificationState(
                    code: VerificationSectionState(status: .success),
                    runtime: VerificationSectionState(status: .success),
                    security: VerificationSectionState(status: .success)
                )
            } else {
                let errorMessage = initialError ?? "Verification failed"
                initialState = VerificationState(
                    code: VerificationSectionState(status: .error, error: errorMessage),
                    runtime: VerificationSectionState(status: .error),
                    security: VerificationSectionState(status: .error)
                )
            }
        } else {
            initialState = VerificationState(
                code: VerificationSectionState(status: .pending),
                runtime: VerificationSectionState(status: .pending),
                security: VerificationSectionState(status: .pending)
            )
        }
        
        _verificationState = State(initialValue: initialState)
    }
    
    var body: some View {
        VStack(spacing: 10) {
            panelHeader
            VerificationStatusView(verificationState: verificationState)
                .padding(.horizontal)
            
            expandedContent
        }
        .padding(.top)
        .background(colorScheme == .dark ? Color.black.opacity(0.8) : Color.white)
    }
    
    // MARK: - Subviews
    
    // Improved header with better styling
    private var panelHeader: some View {
        HStack {
            Text("Enclave Verification")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(colorScheme == .dark ? .white : .primary)
            Spacer()
            
            // Dismiss button
            Button(action: {
                // Dismiss the view controller
                chatViewModel.dismissVerifier()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Close verification screen")
        }
        .padding()
    }
    
    /// The main panel when expanded, including instructions, steps, etc.
    private var expandedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("""
                     This automated verification tool confirms the model is running \
                     in a secure enclave, keeping your conversations private.
                     """)
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                    .padding(.horizontal)
                
                verifyButtonSection
                
                // The steps for code, runtime, security
                ProcessStepView(
                    title: VerificationStepConfig.codeIntegrity.title(for: verificationState.code.status),
                    description: VerificationStepConfig.codeIntegrity.description,
                    status: verificationState.code.status,
                    error: verificationState.code.error,
                    measurements: verificationState.code.digest,
                    steps: verificationState.code.steps,
                    links: [
                        ("GitHub Release", chatViewModel.currentModel.githubReleaseURL)
                    ],
                    stepKey: VerificationStepConfig.codeIntegrity.key
                )
                
                ProcessStepView(
                    title: VerificationStepConfig.remoteAttestation.title(for: verificationState.runtime.status),
                    description: VerificationStepConfig.remoteAttestation.description,
                    status: verificationState.runtime.status,
                    error: verificationState.runtime.error,
                    measurements: verificationState.runtime.digest,
                    steps: verificationState.runtime.steps,
                    stepKey: VerificationStepConfig.remoteAttestation.key
                )
                
                ProcessStepView(
                    title: VerificationStepConfig.codeConsistency.title(for: verificationState.security.status),
                    description: VerificationStepConfig.codeConsistency.description,
                    status: verificationState.security.status,
                    error: verificationState.security.error,
                    measurements: nil,
                    steps: [],
                    stepKey: VerificationStepConfig.codeConsistency.key
                ) {
                    AnyView(
                        Group {
                            if let codeMeasurements = verificationState.code.digest,
                               let runtimeMeasurements = verificationState.runtime.digest {
                                MeasurementDiffView(
                                    sourceMeasurements: codeMeasurements,
                                    runtimeMeasurements: runtimeMeasurements,
                                    isVerified: (verificationState.security.status == .success)
                                )
                            }
                        }
                    )
                }
            }
            .padding()
        }
    }
    
    /// A section containing just the verify button
    private var verifyButtonSection: some View {
        Button(action: {
            // Prevent multiple verification attempts
            guard !isVerifying else { return }
            
            // Run the verification asynchronously
            Task {
                await verifyAll()
            }
        }) {
            HStack {
                if isVerifying {
                    ProgressView()
                        .frame(width: 16, height: 16)
                        .padding(.trailing, 4)
                }
                Text(isVerifying ? "Verifying..." : "Verify Again")
                    .fontWeight(.medium)
            }
            .frame(minWidth: 200)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .disabled(isVerifying)
        .buttonStyle(.borderedProminent)
        .tint(colorScheme == .dark ? Color.gray.opacity(0.3) : Color(hex: "#111827"))
        .shadow(color: colorScheme == .dark ? 
                Color.gray.opacity(0.15) : 
                Color(hex: "#111827").opacity(0.2), 
                radius: 3, x: 0, y: 2)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
    }
    
    // MARK: - Logic placeholders
    
    /// Verification flow of the committed and runtime binaries using remote attestation.
    /// This uses the TinfoilAI implementation with the SecureClient class
    private func verifyAll() async {
        // Update on the main thread
        await MainActor.run {
            isVerifying = true
            // set the status to loading
            verificationState.code.status = .loading
            verificationState.runtime.status = .pending
            verificationState.security.status = .pending
            
            // Update the chatViewModel to show verification is in progress
            chatViewModel.isVerifying = true
            
            // Set all ProcessStepViews to show they are being freshly verified
            // We'll do this by posting a notification that all views can observe
            NotificationCenter.default.post(
                name: Notification.Name("StartingFreshVerification"),
                object: nil
            )
        }

        // Create verification callbacks to update UI as steps complete
        let callbacks = VerificationCallbacks(
            onCodeVerificationComplete: { result in
                Task { @MainActor in
                    switch result.status {
                    case .success:
                        self.verificationState.code.status = .success
                        self.verificationState.code.digest = result.digest
                    case .failure(let error):
                        self.verificationState.code.status = .error
                        self.verificationState.code.error = error.localizedDescription
                        // If code verification fails, we can't continue with the other steps
                        self.verificationState.runtime.status = .error
                        self.verificationState.security.status = .error
                        self.isVerifying = false
                    case .pending, .inProgress:
                        // Update status for pending/in progress states
                        self.verificationState.code.status = result.status.uiStatus
                    }
                }
            },
            onRuntimeVerificationComplete: { result in
                Task { @MainActor in
                    switch result.status {
                    case .success:
                        self.verificationState.runtime.status = .success
                        self.verificationState.runtime.digest = result.digest
                    case .failure(let error):
                        self.verificationState.runtime.status = .error
                        self.verificationState.runtime.error = error.localizedDescription
                        self.verificationState.security.status = .error
                        self.isVerifying = false
                    case .pending, .inProgress:
                        // Update status for pending/in progress states
                        self.verificationState.runtime.status = result.status.uiStatus
                    }
                }
            },
            onSecurityCheckComplete: { result in
                Task { @MainActor in
                    switch result.status {
                    case .success:
                        self.verificationState.security.status = .success
                    case .failure(let error):
                        self.verificationState.security.status = .error
                        self.verificationState.security.error = error.localizedDescription
                    case .pending, .inProgress:
                        // Update status for pending/in progress states
                        self.verificationState.security.status = result.status.uiStatus
                    }
                    self.isVerifying = false
                    
                    // Only update the chat view model on successful verification
                    if case .success = result.status {
                        // Update the chatViewModel's verification status
                        self.chatViewModel.isVerified = true
                        self.chatViewModel.isVerifying = false
                        self.chatViewModel.verificationError = nil
                    } else if case .failure(let error) = result.status {
                        // Update the failed verification status in chatViewModel
                        self.chatViewModel.isVerified = false
                        self.chatViewModel.isVerifying = false
                        self.chatViewModel.verificationError = error.localizedDescription
                    }
                }
            }
        )
        
        // Create a secure client instance
        let secureClient = SecureClient(
            githubRepo: chatViewModel.currentModel.repoName,
            enclaveURL: chatViewModel.currentModel.enclave,
            callbacks: callbacks
        )
        
        // Run the verification process
        do {
            // This will trigger callbacks as each step completes
            let _ = try await secureClient.verify()
            // Note: We don't need to handle the result directly here as the callbacks
            // will update the UI as each step completes
        } catch {
            // Handle any unexpected errors not caught by callbacks
            await MainActor.run {
                if verificationState.code.status != .error {
                    verificationState.code.status = .error
                    verificationState.code.error = "Verification failed: \(error.localizedDescription)"
                }
                if verificationState.runtime.status != .error {
                    verificationState.runtime.status = .error
                }
                if verificationState.security.status != .error {
                    verificationState.security.status = .error
                }
                isVerifying = false
                
                // Update the chatViewModel with the error
                chatViewModel.isVerified = false
                chatViewModel.isVerifying = false
                chatViewModel.verificationError = error.localizedDescription
            }
        }
    }
    
}

// MARK: - VerificationStatusView

struct VerificationStatusView: View {
    let verificationState: VerificationState
    var showDetailsLink: Bool = false
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        let hasErrors = (
            verificationState.code.status == .error ||
            verificationState.runtime.status == .error ||
            verificationState.security.status == .error
        )
        let allSuccess = (
            verificationState.code.status == .success &&
            verificationState.runtime.status == .success &&
            verificationState.security.status == .success
        )
        
        // Enhanced status message with better visual styling
        VStack {
            if hasErrors {
                Label("Verification failed. Please check above errors.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.headline)
            } else if allSuccess {
                VStack(spacing: 8) {
                    Label("All verifications succeeded! Your chat is confidential.", systemImage: "checkmark")
                        .foregroundColor(.green)
                        .font(.headline)
                    if showDetailsLink {
                        Button("View verification details") {
                            // Scroll to details (stub)
                        }
                        .foregroundColor(.blue)
                        .font(.subheadline)
                    }
                }
            } else {
                Label("Verification in progress. Checking code integrity and enclave environment.", systemImage: "clock")
                    .foregroundColor(.blue)
                    .font(.headline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ProcessStepView

struct ProcessStepView: View {
    let title: String
    let description: String
    let status: VerifierStatus
    let error: String?
    let measurements: String?
    let steps: [VerificationStep]
    let links: [(text: String, url: String)]?
    let children: AnyView?
    let stepKey: String
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpen: Bool = false
    
    // Track if this is from initial state or from verify again
    @State private var hasBeenVerified: Bool = false
    
    init(
        title: String,
        description: String,
        status: VerifierStatus,
        error: String?,
        measurements: String?,
        steps: [VerificationStep],
        links: [(text: String, url: String)]? = nil,
        stepKey: String,
        @ViewBuilder children: () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.title = title
        self.description = description
        self.status = status
        self.error = error
        self.measurements = measurements
        self.steps = steps
        self.links = links
        self.children = children()
        self.stepKey = stepKey
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            // Enhanced step header with better visual styling
            Button {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    isOpen.toggle()
                }
            } label: {
                HStack {
                    StatusIcon(status: status)
                        .frame(width: 24, height: 24)
                    Spacer()
                    Text(title)
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .foregroundColor(.secondary)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? 
                              Color(.systemGray6) : 
                              Color(.systemGroupedBackground))
                        .shadow(color: colorScheme == .dark ? 
                                Color.black.opacity(0.3) : 
                                Color.gray.opacity(0.2), 
                                radius: 3, x: 0, y: 2)
                )
            }
            .buttonStyle(PlainButtonStyle())
            
            // When open, show the expanded details (pushing content below it downward).
            if isOpen {
                expandedContent
                    // A simple fade-in transition; you can use .slide, .scale, etc.
                    .transition(.opacity)
            }
        }
        // Animate layout changes for a "bouncy" expand/collapse.
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isOpen)
        .onAppear {
            // Listen for fresh verification notifications
            NotificationCenter.default.addObserver(
                forName: Notification.Name("StartingFreshVerification"),
                object: nil,
                queue: .main
            ) { _ in
                hasBeenVerified = true
            }
        }
        .onDisappear {
            // Clean up notification observer
            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name("StartingFreshVerification"),
                object: nil
            )
        }
    }
    
    /// The expanded details, broken out for clarity.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description:").font(.headline)
                    Text(description)
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                        .font(.subheadline)
                }
            }

            if !steps.isEmpty {
                Text("Steps:")
                    .font(.headline)
                ForEach(steps) { step in
                    if let link = step.link, let url = URL(string: link) {
                        Link(step.text, destination: url)
                            .foregroundColor(.blue)
                    } else {
                        Text(step.text)
                            .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                    }
                }
            }
            
            if let error = error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.1))
                    )
            }
            
            // Only show measurements if they exist AND we've done a fresh verification
            if let measurements = measurements, !measurements.isEmpty, hasBeenVerified {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stepKey == "CODE_INTEGRITY" ? 
                        "Source binary digest" : 
                        "Runtime binary digest").font(.headline)
                    Text(stepKey == "CODE_INTEGRITY" ? 
                        "Received from GitHub and Sigstore" : 
                        "Received from the enclave")
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                        .font(.subheadline)
                        
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(measurements)
                            .font(.system(.subheadline, design: .monospaced))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(colorScheme == .dark ? 
                                          Color(.systemGray5) : 
                                          Color(.systemFill))
                            )
                    }
                   
                }
            }
            
            if let links = links, !links.isEmpty {
                Text("Related Links:").font(.headline)
                ForEach(links.indices, id: \.self) { idx in
                    let link = links[idx]
                    Link(link.text, destination: URL(string: link.url) ?? URL(fileURLWithPath: ""))
                        .foregroundColor(.blue)
                }
            }
            
            // Only show children (measurement diff) if we've done a fresh verification
            if hasBeenVerified {
                children
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? 
                      Color(.systemGray5).opacity(0.5) : 
                      Color(.systemBackground))
                .shadow(color: colorScheme == .dark ? 
                        Color.black.opacity(0.2) : 
                        Color.gray.opacity(0.1), 
                        radius: 2, x: 0, y: 1)
        )
        .padding(.top, 4)
    }
}

// MARK: - MeasurementDiffView

struct MeasurementDiffView: View {
    let sourceMeasurements: String
    let runtimeMeasurements: String
    let isVerified: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Digest Comparison").font(.headline)
                
            Label(isVerified ? "Source and runtime digests match" : "Digest mismatch detected",
                  systemImage: isVerified ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isVerified ? .green : .red)
                .font(.subheadline)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isVerified ? 
                              Color.green.opacity(colorScheme == .dark ? 0.2 : 0.1) : 
                              Color.red.opacity(colorScheme == .dark ? 0.2 : 0.1))
                )
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Source binary digest").font(.headline)
                Text("Received from GitHub and Sigstore")
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                    .font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(sourceMeasurements)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colorScheme == .dark ? 
                                      Color(.systemGray5) : 
                                      Color(.systemFill))
                        )
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Runtime binary digest").font(.headline)
                Text("Received from the enclave")
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                    .font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(runtimeMeasurements)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colorScheme == .dark ? 
                                      Color(.systemGray5) : 
                                      Color(.systemFill))
                        )
                }
            }
        }
        .padding(.top, 10)
    }
}

// MARK: - StatusIcon

/// A small helper view to display status-based icons
struct StatusIcon: View {
    let status: VerifierStatus
    
    var body: some View {
        switch status {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 18, weight: .bold))
        case .loading:
            ProgressView()
                .scaleEffect(1.2)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 18, weight: .bold))
        case .pending:
            Image(systemName: "clock.badge.questionmark")
                .foregroundColor(.gray)
                .font(.system(size: 18, weight: .medium))
        }
    }
} 
