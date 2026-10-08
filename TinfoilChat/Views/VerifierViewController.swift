//
//  VerifierView.swift
//  TinfoilChat
//
//  Created on 2/25/25.
//

import SwiftUI
import TinfoilAI

// MARK: - Verification Section

private enum VerificationSection: String, CaseIterable, Identifiable {
    case runtime
    case code
    case encryption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .encryption: return "Data is Encrypted"
        case .code: return "Code is Auditable"
        case .runtime: return "Runtime is Isolated"
        }
    }

    var iconName: String {
        switch self {
        case .encryption: return "lock"
        case .code: return "terminal"
        case .runtime: return "cpu"
        }
    }
}

// MARK: - VerifierView

struct VerifierView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedSections: Set<VerificationSection> = []

    private var isDarkMode: Bool { colorScheme == .dark }
    private var verificationAccent: Color { .verificationAccent(isDarkMode: isDarkMode) }

    private var sheetBackground: Color {
        isDarkMode ? Color.backgroundPrimary : Color(UIColor.systemBackground)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if chatViewModel.isVerified, let verified = chatViewModel.enclaveVerification {
                    VStack(spacing: 16) {
                        statusBanner(for: verified)
                        drawerList(for: verified)
                    }
                    .padding(.bottom, 32)
                } else if !chatViewModel.isVerifying, let error = chatViewModel.verificationError {
                    failureState(error)
                        .padding(.bottom, 32)
                } else {
                    loadingState
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetBackground.ignoresSafeArea())
            .navigationTitle("Verification Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(sheetBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { chatViewModel.dismissVerifier() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close verification screen")
                }
            }
        }
    }

    // MARK: - Loading and Failure States

    private var loadingState: some View {
        placeholderState(status: .pending) {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.9)
                Text("Verifying secure enclave...")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
            }
        }
    }

    /// The SDK reports a failed verification as a single error, not per
    /// step, so every section shows as failed with nothing to expand.
    private func failureState(_ error: String) -> some View {
        placeholderState(status: .error) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Verification failed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func placeholderState<Banner: View>(
        status: VerifierStatus,
        @ViewBuilder banner: () -> Banner
    ) -> some View {
        VStack(spacing: 16) {
            banner()
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDarkMode ? Color(.systemGray6).opacity(0.5) : Color(.systemGray6))
                )

            VStack(spacing: 0) {
                ForEach(VerificationSection.allCases) { section in
                    drawerHeader(
                        section: section,
                        status: status,
                        isExpanded: false,
                        isEnabled: false,
                        action: {}
                    )

                    if section != VerificationSection.allCases.last {
                        Divider()
                    }
                }
            }
            .background(drawerBackground)
            .clipShape(RoundedRectangle(cornerRadius: Constants.UI.VerificationCenter.drawerCornerRadius))
            .overlay(drawerBorder)
        }
    }

    // MARK: - Status Banner

    private func statusBanner(for verification: Verification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your data is encrypted end-to-end to a server running inside a secure hardware enclave.")
                .font(.system(size: 15))
                .foregroundColor(verificationAccent)

            HStack(spacing: 6) {
                let isSEV = verification.isSEV
                let isTDX = verification.isTDX

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(verificationAccent.opacity(isDarkMode ? 0.1 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(verificationAccent.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Verification Drawers

    private func drawerList(for verification: Verification) -> some View {
        VStack(spacing: 0) {
            ForEach(VerificationSection.allCases) { section in
                let isExpanded = expandedSections.contains(section)

                drawerHeader(
                    section: section,
                    status: .success,
                    isExpanded: isExpanded,
                    action: { toggle(section) }
                )

                VStack(spacing: 0) {
                    if isExpanded {
                        VStack(spacing: 0) {
                            Divider()

                            VStack(alignment: .leading, spacing: Constants.UI.VerificationCenter.drawerContentSpacing) {
                                sectionHeader(for: section)
                                sectionContent(for: verification, section: section)
                            }
                            .padding(.horizontal, Constants.UI.VerificationCenter.drawerContentHorizontalPadding)
                            .padding(.top, Constants.UI.VerificationCenter.drawerContentSpacing)
                            .padding(.bottom, Constants.UI.VerificationCenter.drawerContentBottomPadding)
                        }
                        .transition(.opacity)
                    }
                }

                if section != VerificationSection.allCases.last {
                    Divider()
                }
            }
        }
        .background(drawerBackground)
        .clipShape(RoundedRectangle(cornerRadius: Constants.UI.VerificationCenter.drawerCornerRadius))
        .overlay(drawerBorder)
    }

    private var drawerBackground: some ShapeStyle {
        isDarkMode
            ? Color(.systemGray6).opacity(Constants.UI.VerificationCenter.drawerDarkBackgroundOpacity)
            : Color(UIColor.systemBackground)
    }

    private var drawerBorder: some View {
        RoundedRectangle(cornerRadius: Constants.UI.VerificationCenter.drawerCornerRadius)
            .stroke(
                Color.primary.opacity(
                    isDarkMode
                        ? Constants.UI.VerificationCenter.drawerDarkBorderOpacity
                        : Constants.UI.VerificationCenter.drawerLightBorderOpacity
                ),
                lineWidth: Constants.UI.VerificationCenter.drawerBorderWidth
            )
    }

    private func drawerHeader(
        section: VerificationSection,
        status: VerifierStatus,
        isExpanded: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Constants.UI.VerificationCenter.drawerHeaderSpacing) {
                Image(systemName: section.iconName)
                    .font(.system(size: Constants.UI.VerificationCenter.drawerIconSize, weight: .medium))
                    .foregroundColor(verificationAccent)
                    .frame(width: Constants.UI.VerificationCenter.drawerIconWidth)

                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Spacer()

                statusBadge(status)

                Image(systemName: "chevron.down")
                    .font(.system(size: Constants.UI.VerificationCenter.drawerChevronSize, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: Constants.UI.VerificationCenter.drawerChevronWidth)
                    .rotationEffect(
                        isExpanded
                            ? .degrees(Constants.UI.VerificationCenter.drawerChevronExpandedRotation)
                            : .zero
                    )
            }
            .padding(.horizontal, Constants.UI.VerificationCenter.drawerHeaderHorizontalPadding)
            .frame(minHeight: Constants.UI.VerificationCenter.drawerHeaderMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title), \(statusAccessibilityText(status))")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func toggle(_ section: VerificationSection) {
        withAnimation(
            reduceMotion
                ? nil
                : .smooth(duration: Constants.UI.VerificationCenter.drawerAnimationDuration)
        ) {
            if expandedSections.contains(section) {
                expandedSections.remove(section)
            } else {
                expandedSections.insert(section)
            }
        }
    }

    private func statusAccessibilityText(_ status: VerifierStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .loading: return "verifying"
        case .success: return "verified"
        case .error: return "failed"
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: VerifierStatus) -> some View {
        switch status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(verificationAccent)
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

    @ViewBuilder
    private func sectionHeader(for section: VerificationSection) -> some View {
        switch section {
        case .encryption:
            EncryptionSectionHeader()
        case .code:
            CodeSectionHeader()
        case .runtime:
            RuntimeSectionHeader()
        }
    }

    @ViewBuilder
    private func sectionContent(for verification: Verification, section: VerificationSection) -> some View {
        switch section {
        case .encryption:
            EncryptionSectionCards(
                verification: verification,
                status: .success,
                isDarkMode: isDarkMode
            )
        case .code:
            CodeSectionCards(
                verification: verification,
                status: .success,
                isDarkMode: isDarkMode
            )
        case .runtime:
            RuntimeSectionCards(
                verification: verification,
                status: .success,
                isDarkMode: isDarkMode
            )
        }
    }
}

// MARK: - Section Headers

private struct EncryptionSectionHeader: View {
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

private struct CodeSectionHeader: View {
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

private struct RuntimeSectionHeader: View {
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

// MARK: - Section Cards

private struct EncryptionSectionCards: View {
    let verification: Verification
    let status: VerifierStatus
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 16) {
            FingerprintCard(
                icon: "key.fill",
                label: "Your unique encryption key",
                value: verification.hpkePublicKey ?? "",
                successBadgeText: "Attested",
                status: status,
                isDarkMode: isDarkMode
            )

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Encryption Protocol")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))
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
                        .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))
                    Text(verification.hpkePublicKey ?? "Not available")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct CodeSectionCards: View {
    let verification: Verification
    let status: VerifierStatus
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 16) {
            FingerprintCard(
                icon: "touchid",
                label: "Release digest",
                value: verification.codeDigest,
                successBadgeText: "Verified",
                status: status,
                isDarkMode: isDarkMode
            )

            if let codeMeasurement = verification.codeMeasurement {
                InfoCard(isDarkMode: isDarkMode) {
                    MeasurementList(
                        title: "Code Measurements",
                        measurement: codeMeasurement,
                        isDarkMode: isDarkMode
                    )
                }
            }

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configuration Repository")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))
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
                        text: verification.configRepo,
                        url: "https://github.com/\(verification.configRepo)"
                    )
                }
            }

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sigstore Transparency Log")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))
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
                        url: verification.codeDigest.isEmpty
                            ? "https://search.sigstore.dev"
                            : "https://search.sigstore.dev/?hash=sha256:\(verification.codeDigest)"
                    )
                }
            }
        }
    }
}

private struct RuntimeSectionCards: View {
    let verification: Verification
    let status: VerifierStatus
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 16) {
            FingerprintCard(
                icon: "touchid",
                label: "Enclave TLS key fingerprint",
                value: verification.tlsPublicKeyFingerprint,
                successBadgeText: "Attested",
                status: status,
                isDarkMode: isDarkMode
            )

            InfoCard(isDarkMode: isDarkMode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hardware Attestation")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))
                    Text("The verifier receives a signed measurement from NVIDIA\(verification.isSEV ? ", AMD" : "")\(verification.isTDX ? ", Intel" : "") certifying the enclave environment and the digest of the binary actively running inside it.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        ExternalLink(text: "NVIDIA Attestation", url: "https://docs.nvidia.com/attestation/index.html")
                        if verification.isSEV {
                            ExternalLink(text: "AMD SEV", url: "https://www.amd.com/en/developer/sev.html")
                        }
                        if verification.isTDX {
                            ExternalLink(text: "Intel TDX", url: "https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html")
                        }
                    }
                }
            }

            if let enclaveMeasurement = verification.enclaveMeasurement {
                InfoCard(isDarkMode: isDarkMode) {
                    MeasurementList(
                        title: "Hardware Measurements",
                        measurement: enclaveMeasurement,
                        isDarkMode: isDarkMode
                    )
                }
            }
        }
    }
}

private extension Verification {
    var isSEV: Bool {
        enclaveMeasurement?.type.lowercased().contains("sev") ?? false
    }

    var isTDX: Bool {
        enclaveMeasurement?.type.lowercased().contains("tdx") ?? false
    }
}

// MARK: - Shared Components

private struct FingerprintCard: View {
    let icon: String
    let label: String
    let value: String
    let successBadgeText: String
    let status: VerifierStatus
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

                fingerprintStatus
            }

            Text(value.isEmpty ? "Not available" : value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDarkMode ? Color(.systemGray5).opacity(0.5) : Color(.systemGray6))
        )
    }

    @ViewBuilder
    private var fingerprintStatus: some View {
        switch status {
        case .success:
            HStack(spacing: 4) {
                Text(successBadgeText)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))
        case .error:
            HStack(spacing: 4) {
                Text("Failed")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.red)
        case .loading:
            HStack(spacing: 4) {
                Text("Verifying")
                    .font(.system(size: 13, weight: .medium))
                ProgressView()
                    .scaleEffect(0.6)
            }
            .foregroundColor(.secondary)
        case .pending:
            HStack(spacing: 4) {
                Text("Pending")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.secondary)
        }
    }
}

private struct InfoCard<Content: View>: View {
    let isDarkMode: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDarkMode ? Color(.systemGray5).opacity(0.4) : Color(.systemGray6).opacity(0.7))
            )
    }
}

private struct ExternalLink: View {
    let text: String
    let url: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let linkURL = URL(string: url) {
            Link(destination: linkURL) {
                HStack(spacing: 4) {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Color.verificationAccent(isDarkMode: colorScheme == .dark))
            }
        }
    }
}

private extension Color {
    static func verificationAccent(isDarkMode: Bool) -> Color {
        isDarkMode ? .tinfoilAccentBlueLight : .tinfoilAccentBlue
    }
}

private struct MeasurementList: View {
    let title: String
    let measurement: Verification.Measurement
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.verificationAccent(isDarkMode: isDarkMode))

            MeasurementField(
                label: "Type",
                value: measurement.type
            )

            ForEach(Array(measurement.registers.enumerated()), id: \.offset) { index, register in
                MeasurementField(
                    label: "Register \(index)",
                    value: register
                )
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
