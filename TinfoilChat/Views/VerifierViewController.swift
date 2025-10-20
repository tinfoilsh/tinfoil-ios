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
        description: "Verifies that the source code published publicly by Tinfoil on GitHub was correctly built through GitHub Actions and the resulting binary is available and immutable on the Sigstore transparency log.",
        defaultTitle: "Code Integrity Check",
        loadingTitle: "Checking Code Integrity...",
        successTitle: "Code Integrity Verified"
    )
    
    static let remoteAttestation = Step(
        key: "REMOTE_ATTESTATION",
        description: "Verifies that the secure enclave environment is set up correctly. The response consists of a signed attestation by NVIDIA and AMD of the enclave environment and the measurement of the binary (i.e., code) running inside it.",
        defaultTitle: "Enclave Runtime Attestation",
        loadingTitle: "Fetching Attestation Report...",
        successTitle: "Enclave Runtime Checked"
    )
    
    static let codeConsistency = Step(
        key: "CODE_CONSISTENCY",
        description: "Verifies that the binary built from the source code matches the binary running in the enclave by comparing measurements from the enclave and the transparency log.",
        defaultTitle: "Consistency Check",
        loadingTitle: "Checking Measurements...",
        successTitle: "Measurements Match"
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

    @State private var verificationState: VerificationState

    @EnvironmentObject var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    init(verificationDocument: VerificationDocument? = nil) {
        let initialState: VerificationState

        if let doc = verificationDocument {
            let codeStatus: VerifierStatus = doc.steps.verifyCode.status == .success ? .success : (doc.steps.verifyCode.status == .failed ? .error : .pending)
            let runtimeStatus: VerifierStatus = doc.steps.verifyEnclave.status == .success ? .success : (doc.steps.verifyEnclave.status == .failed ? .error : .pending)
            let securityStatus: VerifierStatus = doc.steps.compareMeasurements.status == .success ? .success : (doc.steps.compareMeasurements.status == .failed ? .error : .pending)

            initialState = VerificationState(
                code: VerificationSectionState(
                    status: codeStatus,
                    error: doc.steps.verifyCode.error,
                    measurementType: doc.codeMeasurement.type,
                    registers: doc.codeMeasurement.registers
                ),
                runtime: VerificationSectionState(
                    status: runtimeStatus,
                    error: doc.steps.verifyEnclave.error,
                    measurementType: doc.enclaveMeasurement.measurement.type,
                    registers: doc.enclaveMeasurement.measurement.registers,
                    tlsCertificateFingerprint: doc.enclaveMeasurement.tlsPublicKeyFingerprint
                ),
                security: VerificationSectionState(
                    status: securityStatus,
                    error: doc.steps.compareMeasurements.error
                )
            )
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
        NavigationView {
            VStack(spacing: 10) {
                VerificationStatusView(verificationState: verificationState)
                    .padding(.horizontal)

                expandedContent
            }
            .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
            .navigationTitle("Verification Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        chatViewModel.dismissVerifier()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close verification screen")
                }
            }
            .onAppear {
                setupNavigationBarAppearance()
            }
        }
    }

    private func setupNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        if #available(iOS 26, *) {
            appearance.configureWithTransparentBackground()
        } else {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = colorScheme == .dark ? UIColor(Color.backgroundPrimary) : .white
        }
        appearance.shadowColor = .clear

        let tintColor: UIColor = colorScheme == .dark ? .white : .black

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = tintColor
    }

    // MARK: - Subviews
    
    /// The main panel when expanded, including instructions, steps, etc.
    private var expandedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("""
                     This automated verification tool lets you independently confirm that \
                     the models are running in secure enclaves, ensuring your \
                     conversations remain completely private.
                     """)
                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                    .padding(.horizontal)
                
                // Related Links section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Related Links")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Link(destination: URL(string: "https://docs.tinfoil.sh/verification/attestation-architecture")!) {
                            HStack {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(.green)
                                Text("Attestation Architecture")
                                    .foregroundColor(.green)
                                    .font(.subheadline)
                                Spacer()
                            }
                        }
                        
                        Link(destination: URL(string: "https://docs.tinfoil.sh/resources/how-it-works")!) {
                            HStack {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(.green)
                                Text("How It Works")
                                    .foregroundColor(.green)
                                    .font(.subheadline)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)

                // The steps for code, runtime, security
                ProcessStepView(
                    title: VerificationStepConfig.codeIntegrity.title(for: verificationState.code.status),
                    description: VerificationStepConfig.codeIntegrity.description,
                    status: verificationState.code.status,
                    error: verificationState.code.error,
                    measurementType: verificationState.code.measurementType,
                    registers: verificationState.code.registers,
                    steps: verificationState.code.steps,
                    links: [
                        ("GitHub Release", Constants.Proxy.githubReleaseURL)
                    ],
                    stepKey: VerificationStepConfig.codeIntegrity.key
                )

                ProcessStepView(
                    title: VerificationStepConfig.remoteAttestation.title(for: verificationState.runtime.status),
                    description: VerificationStepConfig.remoteAttestation.description,
                    status: verificationState.runtime.status,
                    error: verificationState.runtime.error,
                    measurementType: verificationState.runtime.measurementType,
                    registers: verificationState.runtime.registers,
                    steps: verificationState.runtime.steps,
                    stepKey: VerificationStepConfig.remoteAttestation.key,
                    tlsCertificateFingerprint: verificationState.runtime.tlsCertificateFingerprint
                )

                ProcessStepView(
                    title: VerificationStepConfig.codeConsistency.title(for: verificationState.security.status),
                    description: VerificationStepConfig.codeConsistency.description,
                    status: verificationState.security.status,
                    error: verificationState.security.error,
                    measurementType: nil,
                    registers: nil,
                    steps: [],
                    stepKey: VerificationStepConfig.codeConsistency.key
                ) {
                    AnyView(
                        Group {
                            if let codeRegisters = verificationState.code.registers,
                               let runtimeRegisters = verificationState.runtime.registers {
                                MeasurementDiffView(
                                    sourceMeasurementType: verificationState.code.measurementType,
                                    sourceRegisters: codeRegisters,
                                    runtimeMeasurementType: verificationState.runtime.measurementType,
                                    runtimeRegisters: runtimeRegisters,
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
        VStack(spacing: 0) {
            VStack {
                if hasErrors {
                    Label("Verification failed. Please check the verification details below for errors.", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.headline)
                } else if allSuccess {
                    VStack(spacing: 8) {
                        Label("All verifications succeeded! Your chat is secure and confidential.", systemImage: "checkmark")
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
            
            Rectangle()
                .fill(Color.white)
                .frame(height: 1)
                .opacity(0.3)
        }
    }
}

// MARK: - ProcessStepView

struct ProcessStepView: View {
    let title: String
    let description: String
    let status: VerifierStatus
    let error: String?
    let measurementType: String?
    let registers: [String]?
    let steps: [VerificationStep]
    let links: [(text: String, url: String)]?
    let children: AnyView?
    let stepKey: String
    let tlsCertificateFingerprint: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpen: Bool = false


    init(
        title: String,
        description: String,
        status: VerifierStatus,
        error: String?,
        measurementType: String?,
        registers: [String]?,
        steps: [VerificationStep],
        links: [(text: String, url: String)]? = nil,
        stepKey: String,
        tlsCertificateFingerprint: String? = nil,
        @ViewBuilder children: () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.title = title
        self.description = description
        self.status = status
        self.error = error
        self.measurementType = measurementType
        self.registers = registers
        self.steps = steps
        self.links = links
        self.children = children()
        self.stepKey = stepKey
        self.tlsCertificateFingerprint = tlsCertificateFingerprint
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
            
            // Show measurements if available
            if let registers = registers, !registers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(stepKey == "CODE_INTEGRITY" ?
                            "Source Measurement" :
                            "Runtime Measurement").font(.headline)

                        if stepKey == "CODE_INTEGRITY" {
                            Image("git-icon")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                                .opacity(0.7)
                        } else if stepKey == "REMOTE_ATTESTATION" {
                            HStack(spacing: 4) {
                                Image("cpu-icon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 28, height: 14)
                                    .opacity(0.7)
                                Text("+")
                                    .font(.system(size: 14))
                                    .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                                    .opacity(0.7)
                                Image("gpu-icon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 28, height: 14)
                                    .opacity(0.7)
                            }
                        }

                        Spacer()
                    }

                    if let type = measurementType {
                        Text(type)
                            .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                            .font(.system(.caption, design: .monospaced))
                    }

                    Text(stepKey == "CODE_INTEGRITY" ?
                        "Received from GitHub and Sigstore." :
                        "Received from the enclave.")
                        .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                        .font(.subheadline)

                    ForEach(Array(registers.enumerated()), id: \.offset) { index, register in
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(register)
                                .font(.system(.subheadline, design: .monospaced))
                                .padding(8)
                        }
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
            
            
            // Show TLS certificate fingerprint for runtime attestation
            if stepKey == "REMOTE_ATTESTATION",
               let tlsFingerprint = tlsCertificateFingerprint,
               !tlsFingerprint.isEmpty {
                TLSCertificateFingerprintView(fingerprint: tlsFingerprint)
            }
            
            // Show provider icons based on step type
            if stepKey == "REMOTE_ATTESTATION" && status == .success {
                ProviderIconsView(
                    providers: [
                        (name: "NVIDIA", icon: "nvidia-icon", url: "https://docs.nvidia.com/attestation/index.html"),
                        (name: "AMD", icon: "amd-icon", url: "https://www.amd.com/en/developer/sev.html")
                    ],
                    title: "Runtime attested by:"
                )
                .padding(.top, 8)
            } else if stepKey == "CODE_INTEGRITY" && status == .success {
                ProviderIconsView(
                    providers: [
                        (name: "GitHub", icon: "github-icon", url: "https://github.com/\(Constants.Proxy.githubRepo)"),
                        (name: "Sigstore", icon: "sigstore-icon", url: "https://search.sigstore.dev/")
                    ],
                    title: "Code integrity attested by:"
                )
                .padding(.top, 8)
            }
            
            // Show additional children content
            children
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

// MARK: - TLSCertificateFingerprintView

struct TLSCertificateFingerprintView: View {
    let fingerprint: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCopiedToast = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("TLS Public Key Fingerprint").font(.headline)
                Image("cert-icon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .opacity(0.7)
                Spacer()
            }
            Text("Fingerprint of the TLS public key used by the enclave to encrypt the connection.")
                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                .font(.subheadline)
            
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(fingerprint)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(12)
                }
                
                Button {
                    UIPasteboard.general.string = fingerprint
                    withAnimation {
                        showCopiedToast = true
                    }
                    
                    // Hide toast after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showCopiedToast = false
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorScheme == .dark ? 
                          Color(.systemGray5) : 
                          Color(.systemFill))
            )
            .overlay(
                showCopiedToast ? 
                    Text("Copied!")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .offset(y: -30)
                        .transition(.opacity)
                : nil
            )
        }
        .padding(.top, 10)
    }
}

// MARK: - MeasurementDiffView

struct MeasurementDiffView: View {
    let sourceMeasurementType: String?
    let sourceRegisters: [String]
    let runtimeMeasurementType: String?
    let runtimeRegisters: [String]
    let isVerified: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isVerified ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(isVerified ? .green : .red)
                Text(isVerified ? "Source and runtime measurements match" : "Measurement mismatch detected")
                    .foregroundColor(isVerified ? .green : .red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
            }
            .font(.subheadline)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isVerified ?
                          Color.green.opacity(colorScheme == .dark ? 0.2 : 0.1) :
                          Color.red.opacity(colorScheme == .dark ? 0.2 : 0.1))
            )
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

// MARK: - ProviderIconsView

/// View to display verification provider icons
struct ProviderIconsView: View {
    let providers: [(name: String, icon: String, url: String)]
    let title: String
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            
            HStack(spacing: 12) {
                ForEach(providers, id: \.name) { provider in
                    Link(destination: URL(string: provider.url)!) {
                        VStack(spacing: 4) {
                            Image(provider.icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: provider.name == "AMD" ? 45 : 60, height: provider.name == "AMD" ? 14 : 22)
                                .frame(height: 22, alignment: .center) // Fixed height container for all icons
                            
                            Text(provider.name)
                                .font(.system(size: 10))
                                .foregroundColor(colorScheme == .dark ? .gray : .secondary)
                        }
                        .frame(width: 80, height: 50, alignment: .bottom) // Align content to bottom
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.cardSurface(for: colorScheme))
                        )
                    }
                }
            }
        }
    }
} 
