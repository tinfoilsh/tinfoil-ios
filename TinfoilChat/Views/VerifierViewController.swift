//
//  VerifierView.swift
//  TinfoilChat
//
//  Created on 2/25/25.
//

import SwiftUI
import TinfoilAI

// MARK: - Tab Model

private enum VerificationTab: String, CaseIterable, Identifiable {
    case encryption
    case code
    case runtime

    var id: String { rawValue }

    var prefix: String {
        switch self {
        case .encryption: return "Data is"
        case .code: return "Code is"
        case .runtime: return "Runtime is"
        }
    }

    var label: String {
        switch self {
        case .encryption: return "Encrypted"
        case .code: return "Auditable"
        case .runtime: return "Isolated"
        }
    }

    var iconName: String {
        switch self {
        case .encryption: return "lock.fill"
        case .code: return "terminal.fill"
        case .runtime: return "cpu.fill"
        }
    }
}

// MARK: - VerifierView

struct VerifierView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: VerificationTab = .encryption

    private var isDarkMode: Bool { colorScheme == .dark }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let doc = chatViewModel.verificationDocument {
                    statusBanner(for: doc)
                    tabSelector(for: doc)

                    tabHeader(for: doc)

                    ScrollView {
                        tabContent(for: doc, tab: selectedTab)
                            .padding(.bottom, 32)
                    }
                } else {
                    loadingState
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .navigationTitle("Verification Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { chatViewModel.dismissVerifier() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close verification screen")
                }
            }
            .onAppear { setupNavigationBarAppearance() }
        }
    }

    private func setupNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.9)
                Text("Verifying secure enclave...")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDarkMode ? Color(.systemGray6).opacity(0.5) : Color(.systemGray6))
            )

            HStack(spacing: 0) {
                ForEach(VerificationTab.allCases) { tab in
                    tabCard(tab: tab, status: .pending, isSelected: false)
                    if tab != .runtime {
                        Spacer(minLength: 12)
                    }
                }
            }
        }
    }

    // MARK: - Status Banner

    private func statusBanner(for doc: VerificationDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if doc.securityVerified {
                Text("Your data is encrypted end-to-end to a server running inside a secure hardware enclave.")
                    .font(.system(size: 15))
                    .foregroundColor(Color.tinfoilAccentLight)

                HStack(spacing: 6) {
                    let isSEV = doc.enclaveMeasurement.measurement.type.lowercased().contains("sev")
                    let isTDX = doc.enclaveMeasurement.measurement.type.lowercased().contains("tdx")

                    Text("Hardware attested by")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)

                    if isSEV {
                        Image("amd-icon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                    }

                    if isTDX {
                        Image("intel-icon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                    }

                    if isSEV || isTDX {
                        Text("and")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }

                    Image("nvidia-icon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 12)
                }
            } else if let error = doc.getFirstError() {
                Text("Verification failed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Verifying secure enclave...")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(doc.securityVerified
                      ? Color.tinfoilAccentLight.opacity(isDarkMode ? 0.1 : 0.08)
                      : (isDarkMode ? Color(.systemGray6).opacity(0.5) : Color(.systemGray6)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(doc.securityVerified
                        ? Color.tinfoilAccentLight.opacity(0.3)
                        : Color.clear,
                        lineWidth: 1)
        )
    }

    // MARK: - Tab Selector

    private func tabSelector(for doc: VerificationDocument) -> some View {
        HStack(spacing: 0) {
            ForEach(VerificationTab.allCases) { tab in
                let status = tabStatus(tab, doc: doc)
                tabCard(tab: tab, status: status, isSelected: selectedTab == tab)
                    .onTapGesture { selectedTab = tab }
                if tab != .runtime {
                    Spacer(minLength: 12)
                }
            }
        }
    }

    private func tabCard(tab: VerificationTab, status: VerifierStatus, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Text(tab.prefix)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? Color.tinfoilAccentLight : .secondary)
            Text(tab.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected ? Color.tinfoilAccentLight : .primary)
            Image(systemName: tab.iconName)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? Color.tinfoilAccentLight : .secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDarkMode ? Color(.systemGray6).opacity(0.5) : Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.tinfoilAccentLight : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) {
            statusBadge(status)
                .offset(x: 6, y: -6)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: VerifierStatus) -> some View {
        switch status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(Color.tinfoilAccentLight)
                .background(Circle().fill(isDarkMode ? Color.backgroundPrimary : .white).padding(2))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.red)
                .background(Circle().fill(isDarkMode ? Color.backgroundPrimary : .white).padding(2))
        case .loading:
            ZStack {
                Circle()
                    .fill(isDarkMode ? Color.backgroundPrimary : .white)
                    .frame(width: 20, height: 20)
                ProgressView()
                    .scaleEffect(0.6)
            }
        case .pending:
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 18, height: 18)
        }
    }

    private func tabStatus(_ tab: VerificationTab, doc: VerificationDocument) -> VerifierStatus {
        switch tab {
        case .encryption:
            if let verifyHPKE = doc.steps.verifyHPKEKey {
                return verifyHPKE.status.uiStatus
            }
            return doc.securityVerified ? .success : .loading
        case .code:
            return doc.steps.verifyCode.status.uiStatus
        case .runtime:
            return doc.steps.verifyEnclave.status.uiStatus
        }
    }

    // MARK: - Tab Header (fixed)

    @ViewBuilder
    private func tabHeader(for doc: VerificationDocument) -> some View {
        switch selectedTab {
        case .encryption:
            EncryptionTabHeader()
        case .code:
            CodeTabHeader()
        case .runtime:
            RuntimeTabHeader()
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for doc: VerificationDocument, tab: VerificationTab) -> some View {
        switch tab {
        case .encryption:
            EncryptionTabCards(document: doc, isDarkMode: isDarkMode)
        case .code:
            CodeTabCards(document: doc, isDarkMode: isDarkMode)
        case .runtime:
            RuntimeTabCards(document: doc, isDarkMode: isDarkMode)
        }
    }
}

// MARK: - Tab Headers (fixed)

private struct EncryptionTabHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Data is encrypted")
                .font(.system(size: 18, weight: .bold))
            Text("Your data is encrypted using a unique key generated inside the secure hardware enclave and verified on your device.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodeTabHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Code is auditable")
                .font(.system(size: 18, weight: .bold))
            Text("All the code that is processing your data comes from a trusted open-source repository and is auditable through the Sigstore transparency log.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RuntimeTabHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime is isolated")
                .font(.system(size: 18, weight: .bold))
            Text("The secure hardware enclave that processes your data has been attested and is verified. The code it is running matches the auditable open-source repository.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tab Cards (scrollable)

private struct EncryptionTabCards: View {
    let document: VerificationDocument
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 12) {
            FingerprintCard(
                icon: "key.fill",
                label: "Your unique encryption key",
                value: document.hpkePublicKey,
                badgeText: "Attested",
                badgeSuccess: true,
                isDarkMode: isDarkMode
            )

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Encryption Protocol")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.tinfoilAccentLight)
                    Text("EHBP (Encrypted HTTP Body Protocol) encrypts HTTP message bodies end-to-end using HPKE, ensuring only the intended recipient can decrypt the payload.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ExternalLink(text: "Learn more about EHBP", url: "https://docs.tinfoil.sh/resources/ehbp")
                }
            }

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full HPKE Public Key")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.tinfoilAccentLight)
                    Text(document.hpkePublicKey)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct CodeTabCards: View {
    let document: VerificationDocument
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 12) {
            FingerprintCard(
                icon: "touchid",
                label: "Source code fingerprint",
                value: document.codeFingerprint,
                badgeText: "Verified",
                badgeSuccess: true,
                isDarkMode: isDarkMode
            )

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full Code Fingerprint")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.tinfoilAccentLight)
                    Text(document.codeFingerprint)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configuration Repository")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color.tinfoilAccentLight)
                            Text("The configuration repository specifies exactly what code is running inside the secure enclave, including dependencies and build instructions.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image("github-icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    ExternalLink(
                        text: document.configRepo,
                        url: "https://github.com/\(document.configRepo)"
                    )
                }
            }

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sigstore Transparency Log")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color.tinfoilAccentLight)
                            Text("Verifies that the source code published on GitHub was correctly built through GitHub Actions and that the resulting binary is available on the Sigstore transparency log.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image("sigstore-icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    ExternalLink(
                        text: "View on Sigstore",
                        url: document.releaseDigest.isEmpty
                            ? "https://search.sigstore.dev"
                            : "https://search.sigstore.dev/?hash=sha256:\(document.releaseDigest)"
                    )
                }
            }
        }
    }
}

private struct RuntimeTabCards: View {
    let document: VerificationDocument
    let isDarkMode: Bool

    private var isSEV: Bool {
        document.enclaveMeasurement.measurement.type.lowercased().contains("sev")
    }

    private var isTDX: Bool {
        document.enclaveMeasurement.measurement.type.lowercased().contains("tdx")
    }

    var body: some View {
        VStack(spacing: 12) {
            FingerprintCard(
                icon: "touchid",
                label: "Enclave code fingerprint",
                value: document.enclaveFingerprint,
                badgeText: "Attested",
                badgeSuccess: true,
                isDarkMode: isDarkMode
            )

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hardware Attestation")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.tinfoilAccentLight)
                    Text("The verifier receives a signed measurement from NVIDIA\(isSEV ? ", AMD" : "")\(isTDX ? ", Intel" : "") certifying the enclave environment and the digest of the binary actively running inside it.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        ExternalLink(text: "NVIDIA Attestation", url: "https://docs.nvidia.com/attestation/index.html")
                        if isSEV {
                            ExternalLink(text: "AMD SEV", url: "https://www.amd.com/en/developer/sev.html")
                        }
                        if isTDX {
                            ExternalLink(text: "Intel TDX", url: "https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html")
                        }
                    }
                }
            }

            if let tlsFingerprint = document.enclaveMeasurement.tlsPublicKeyFingerprint, !tlsFingerprint.isEmpty {
                InfoCard(isDarkMode: isDarkMode) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TLS Public Key Fingerprint")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color.tinfoilAccentLight)
                        Text(tlsFingerprint)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hardware Measurements")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.tinfoilAccentLight)

                    MeasurementField(
                        label: "Type",
                        value: document.enclaveMeasurement.measurement.type
                    )

                    ForEach(Array(document.enclaveMeasurement.measurement.registers.enumerated()), id: \.offset) { index, register in
                        MeasurementField(
                            label: "Register \(index)",
                            value: register
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Shared Components

private struct FingerprintCard: View {
    let icon: String
    let label: String
    let value: String
    let badgeText: String
    let badgeSuccess: Bool
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Text(badgeText)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: badgeSuccess ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(badgeSuccess ? Color.tinfoilAccentLight : .red)
            }

            Text(value.isEmpty ? "Not available" : value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDarkMode ? Color(.systemGray5).opacity(0.5) : Color(.systemGray6))
        )
    }
}

private struct InfoCard<Content: View>: View {
    let isDarkMode: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDarkMode ? Color(.systemGray5).opacity(0.4) : Color(.systemGray6).opacity(0.7))
            )
    }
}

private struct ExternalLink: View {
    let text: String
    let url: String

    var body: some View {
        if let linkURL = URL(string: url) {
            Link(destination: linkURL) {
                HStack(spacing: 4) {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Color.tinfoilAccentLight)
            }
        }
    }
}

private struct MeasurementField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}


