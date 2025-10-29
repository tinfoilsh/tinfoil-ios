//
//  VerifierView.swift
//  TinfoilChat
//
//  Created on 2/25/25.
//

import SwiftUI
import TinfoilAI 

/// Pure SwiftUI implementation of the Verifier view
struct VerifierView: View {

    @State private var verificationDocument: VerificationDocument?

    @EnvironmentObject var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    init(verificationDocument: VerificationDocument? = nil) {
        _verificationDocument = State(initialValue: verificationDocument)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    if let doc = verificationDocument {
                        VerificationStatusView(document: doc)
                            .padding(.top, 16)

                        expandedContent(for: doc)
                    } else {
                        LoadingPlaceholderView()
                            .padding(.top, 16)
                    }
                }
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
    private func expandedContent(for doc: VerificationDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ProcessStepView(
                title: "Runtime Verified",
                document: doc,
                stepType: .remoteAttestation
            )

            ProcessStepView(
                title: "Source Code Verified",
                document: doc,
                stepType: .sourceCode
            )

            ProcessStepView(
                title: "Fingerprints Verified",
                document: doc,
                stepType: .fingerprints
            )

            ProcessStepView(
                title: "About In-App Verification",
                document: doc,
                stepType: .about
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
    
    
}

// MARK: - LoadingPlaceholderView

struct LoadingPlaceholderView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                ProgressView()
                    .scaleEffect(0.9)
                    .frame(width: 24, height: 24)

                Text("Security verification in progress...")
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ?
                          Color(.systemGray6).opacity(0.5) :
                          Color(.systemGray6))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            VStack(spacing: 16) {
                LoadingStepView(title: "Runtime Verified")
                LoadingStepView(title: "Source Code Verified")
                LoadingStepView(title: "Fingerprints Verified")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }
}

struct LoadingStepView: View {
    let title: String
    var isAbout: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            if isAbout {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24, height: 24)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 24, height: 24)
            }

            Text(title)
                .font(.headline)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            Spacer()
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
}

// MARK: - VerificationStatusView

struct VerificationStatusView: View {
    let document: VerificationDocument

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enclave security verified")
                .font(.headline)
                .foregroundColor(.green)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
                Text("The AI model is running in a secure enclave.")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
                Text("The code is open source on GitHub.")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            HStack(alignment: .top, spacing: 4) {
                Text("Attested by")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Image("nvidia-icon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 12)

                    Text("·")
                        .foregroundColor(.secondary)

                    if document.enclaveMeasurement.measurement.type.lowercased().contains("tdx") {
                        Image("intel-icon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                    } else if document.enclaveMeasurement.measurement.type.lowercased().contains("sev") {
                        Image("amd-icon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(colorScheme == .dark ? 0.15 : 0.1))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
    }
}

// MARK: - ProcessStepView

enum StepType {
    case remoteAttestation
    case sourceCode
    case fingerprints
    case about
}

struct ProcessStepView: View {
    let title: String
    let document: VerificationDocument
    let stepType: StepType

    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpen: Bool = false

    var status: VerifierStatus {
        switch stepType {
        case .remoteAttestation:
            return document.steps.verifyEnclave.status.uiStatus
        case .sourceCode:
            return document.steps.verifyCode.status.uiStatus
        case .fingerprints:
            return document.steps.compareMeasurements.status.uiStatus
        case .about:
            return .success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    isOpen.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    if stepType == .about {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 24, height: 24)
                    } else {
                        StatusIcon(status: status)
                            .frame(width: 24, height: 24)
                    }

                    Text(title)
                        .font(.headline)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)

                    Spacer()

                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
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

            if isOpen {
                expandedContent
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isOpen)
    }
    
    /// The expanded details, broken out for clarity.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch stepType {
            case .remoteAttestation:
                remoteAttestationContent
            case .sourceCode:
                sourceCodeContent
            case .fingerprints:
                fingerprintsContent
            case .about:
                aboutContent
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

    private var remoteAttestationContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enclave Fingerprint")
                .font(.headline)

            Text("Fingerprint of the binary running in the secure enclave.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            FingerprintBox(text: document.enclaveFingerprint)

            HStack(alignment: .top, spacing: 4) {
                Text("Runtime attested by")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Image("nvidia-icon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 12)

                    if document.enclaveMeasurement.measurement.type.lowercased().contains("tdx") {
                        Image("intel-icon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                    } else if document.enclaveMeasurement.measurement.type.lowercased().contains("sev") {
                        Image("amd-icon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                    }
                }
            }

            Text("This step verifies the secure hardware environment. The verifier receives a signed measurement from a combination of NVIDIA, AMD, and Intel certifying the enclave environment and the digest of the binary (i.e., code) actively running inside it.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceCodeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Fingerprint")
                .font(.headline)

            Text("Fingerprint of the source binary built from the open source code published on GitHub and Sigstore.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            FingerprintBox(text: document.codeFingerprint)

            HStack(alignment: .top, spacing: 4) {
                Text("Code attested by")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Image("github-icon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 16)

                    Image("sigstore-icon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 16)
                }
            }

            Text("This step verifies that the source code published publicly by Tinfoil on GitHub was correctly built through GitHub Actions and that the resulting binary is available on the Sigstore transparency log.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fingerprintsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Measurement verification passed")
                    .foregroundColor(.green)
                    .font(.subheadline)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(colorScheme == .dark ? 0.15 : 0.1))
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Runtime Fingerprint")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Received from the enclave.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                FingerprintBox(text: document.enclaveFingerprint)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Source Fingerprint")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Received from GitHub and Sigstore.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                FingerprintBox(text: document.codeFingerprint)
            }

            Text("This step verifies that the binary built from the source code matches the binary running in the secure enclave by comparing the fingerprints from the enclave and the expected fingerprints from the transparency log.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The client-side verification tool independently confirms that the models are running in secure enclaves, ensuring your conversations remain completely private.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Link(destination: URL(string: "https://docs.tinfoil.sh/verification/attestation-architecture")!) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                        Text("Attestation architecture")
                            .foregroundColor(.green)
                            .font(.subheadline)
                        Spacer()
                    }
                }

                Link(destination: URL(string: "https://github.com/\(document.configRepo)")!) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                        Text("Server Code")
                            .foregroundColor(.green)
                            .font(.subheadline)
                        Spacer()
                    }
                }

                Link(destination: URL(string: "https://tinfoilsh.github.io/verifier/")!) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                        Text("Verifier Code")
                            .foregroundColor(.green)
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - FingerprintBox

struct FingerprintBox: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ?
                      Color(.systemGray6) :
                      Color(.systemGray6))
        )
    }
}

// MARK: - StatusIcon

struct StatusIcon: View {
    let status: VerifierStatus

    var body: some View {
        switch status {
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 18, weight: .bold))
        case .loading:
            ProgressView()
                .scaleEffect(1.0)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 18, weight: .bold))
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.gray)
                .font(.system(size: 18, weight: .medium))
        }
    }
} 
