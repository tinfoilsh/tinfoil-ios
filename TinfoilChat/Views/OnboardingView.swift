//
//  OnboardingView.swift
//  TinfoilChat
//
//  Onboarding flow shown on first launch to introduce privacy,
//  end-to-end encryption, and available AI models.
//

import SwiftUI

// MARK: - Onboarding Flow Container

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfig.shared
    var onComplete: () -> Void

    @State private var currentPage = 0
    @State private var direction: Edge = .trailing
    @State private var privacyEnabled = false

    private let totalPages = 3

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                ZStack {
                    switch currentPage {
                    case 0:
                        OnboardingPrivacyPage(isPrivacyEnabled: $privacyEnabled)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    case 1:
                        OnboardingEncryptionPage()
                            .transition(.asymmetric(
                                insertion: .move(edge: direction).combined(with: .opacity),
                                removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)
                            ))
                    case 2:
                        OnboardingModelsPage(models: appConfig.availableModels)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    default:
                        EmptyView()
                    }
                }
                .frame(maxHeight: .infinity)

                // Bottom navigation area
                VStack(spacing: 20) {
                    // Page dots
                    HStack(spacing: 8) {
                        ForEach(0..<totalPages, id: \.self) { index in
                            Capsule()
                                .fill(index == currentPage ? Color.accentPrimary : Color.secondary.opacity(0.3))
                                .frame(width: index == currentPage ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                        }
                    }

                    // Continue / Get Started button
                    let canContinue = currentPage != 0 || privacyEnabled
                    Button(action: handleContinue) {
                        Text(currentPage == totalPages - 1 ? "Get Started" : "Continue")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(canContinue
                                ? (colorScheme == .dark ? .black : .white)
                                : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(canContinue
                                        ? (colorScheme == .dark ? Color.white : Color.black)
                                        : Color.secondary.opacity(0.2))
                            )
                    }
                    .disabled(!canContinue)
                    .animation(.easeInOut(duration: 0.3), value: canContinue)
                    .padding(.horizontal, 24)

                    // Skip button (not on last page)
                    if currentPage < totalPages - 1 {
                        Button(action: { onComplete() }) {
                            Text("Skip")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        // Spacer to maintain layout
                        Text(" ")
                            .font(.subheadline)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private var backgroundGradient: some View {
        Group {
            if colorScheme == .dark {
                Color.backgroundPrimary
            } else {
                Color.white
            }
        }
    }

    private func handleContinue() {
        if currentPage < totalPages - 1 {
            direction = .trailing
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                currentPage += 1
            }
        } else {
            onComplete()
        }
    }
}

// MARK: - Screen 1: Privacy

private struct OnboardingPrivacyPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPrivacyEnabled: Bool
    @State private var isPrivateOn = false
    @State private var showExplanation = false
    @State private var shimmerOffset: CGFloat = 0
    @State private var borderRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: isPrivateOn ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.primary)
                        .contentTransition(.symbolEffect(.replace))

                    Text("Privacy First")
                        .font(.title)
                        .fontWeight(.bold)
                }

                Text("Tinfoil is built for people who believe their conversations are nobody else's business.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // The big privacy toggle
            privacyToggleCard

            // Explanation that appears after toggle
            if showExplanation {
                VStack(spacing: 12) {
                    explanationRow(
                        icon: "eye.slash.fill",
                        title: "Zero Access",
                        description: "Your messages are encrypted directly to AI models inside secure hardware. Tinfoil cannot read them."
                    )

                    explanationRow(
                        icon: "checkmark.shield.fill",
                        title: "Verifiable Privacy",
                        description: "Our infrastructure runs on confidential computing GPUs with hardware attestation you can verify."
                    )

                    explanationRow(
                        icon: "lock.doc.fill",
                        title: "Everything is Protected",
                        description: "Chats, images, documents, and voice input are all encrypted end-to-end."
                    )
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()
        }
    }

    private var privacyToggleCard: some View {
        Button(action: togglePrivacy) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isPrivateOn ? "Private" : "Tap to enable privacy")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    if isPrivateOn {
                        Text("Your conversations are protected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Custom animated toggle
                ZStack {
                    Capsule()
                        .fill(isPrivateOn ? Color.accentPrimary : Color.secondary.opacity(0.3))
                        .frame(width: 56, height: 32)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        .offset(x: isPrivateOn ? 12 : -12)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPrivateOn)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isPrivateOn
                        ? Color.accentPrimary.opacity(colorScheme == .dark ? 0.15 : 0.08)
                        : Color(UIColor.secondarySystemBackground))
            )
            .overlay {
                if !isPrivateOn {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.04), location: 0.4),
                                .init(color: .white.opacity(0.06), location: 0.5),
                                .init(color: .white.opacity(0.04), location: 0.6),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.7)
                        .offset(x: -geo.size.width * 0.7 + shimmerOffset * (geo.size.width * 2.1))
                        .onAppear {
                            shimmerOffset = 0
                            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                                shimmerOffset = 1
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if isPrivateOn {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentPrimary.opacity(0.3), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            AngularGradient(
                                stops: [
                                    .init(color: Color.accentPrimary.opacity(0.05), location: 0),
                                    .init(color: Color.accentPrimary.opacity(0.1), location: 0.1),
                                    .init(color: Color.accentPrimary.opacity(0.5), location: 0.2),
                                    .init(color: Color.accentPrimary.opacity(0.1), location: 0.3),
                                    .init(color: Color.accentPrimary.opacity(0.05), location: 0.4),
                                    .init(color: Color.accentPrimary.opacity(0.05), location: 1),
                                ],
                                center: .center,
                                angle: .degrees(borderRotation)
                            ),
                            lineWidth: 1
                        )
                        .onAppear {
                            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                                borderRotation = 360
                            }
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private func togglePrivacy() {
        withAnimation(.easeInOut(duration: 0.5)) {
            isPrivateOn = true
            isPrivacyEnabled = true
        }

        if settings.hapticFeedbackEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }

        pulseScale = 1.08
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.6)) {
                showExplanation = true
            }
        }
    }

    private func explanationRow(icon: String, title: String, description: String) -> some View {
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
}

// MARK: - Screen 2: Encryption

private struct OnboardingEncryptionPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animateKey = false
    @State private var animateShield = false
    @State private var showDetails = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 32) {
                Spacer().frame(height: 40)

                // Animated encryption visualization
                ZStack {
                    // Outer ring
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(0.2),
                            lineWidth: 2
                        )
                        .frame(width: 120, height: 120)
                        .scaleEffect(animateShield ? 1.0 : 0.8)
                        .opacity(animateShield ? 1.0 : 0)

                    // Phone icon with key
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: 88, height: 88)

                        Image(systemName: "iphone")
                            .font(.system(size: 36))
                            .foregroundColor(.primary)

                        // Key badge
                        Image(systemName: "key.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                            .padding(6)
                            .background(
                                Circle()
                                    .fill(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
                            )
                            .offset(x: 28, y: -28)
                            .scaleEffect(animateKey ? 1.0 : 0)
                            .opacity(animateKey ? 1.0 : 0)
                    }
                }
                .onAppear {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.2)) {
                        animateShield = true
                    }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.5)) {
                        animateKey = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            showDetails = true
                        }
                    }
                }

                VStack(spacing: 12) {
                    Text("Your Key, Your Data")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Every chat is encrypted with a key that only exists on your device. Nobody else can read your messages.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if showDetails {
                    VStack(spacing: 0) {
                        encryptionDetailRow(
                            icon: "key.fill",
                            title: "Device-Only Key",
                            description: "Your encryption key never leaves your device. It's the only way to decrypt your conversations.",
                            isLast: true
                        )
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer().frame(height: 20)
            }
        }
    }

    private func encryptionDetailRow(icon: String, title: String, description: String, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .frame(width: 28, height: 28)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !isLast {
                Divider()
                    .padding(.leading, 58)
            }
        }
    }
}

// MARK: - Screen 3: Models

private struct OnboardingModelsPage: View {
    @Environment(\.colorScheme) private var colorScheme
    let models: [ModelType]

    @State private var selectedModelIndex = 0
    @State private var showFeatures = false

    private let features: [(icon: String, label: String)] = [
        ("camera.fill", "Image Upload"),
        ("doc.text.fill", "Document Processing"),
        ("globe", "Web Search"),
        ("waveform", "Voice Input"),
        ("brain.head.profile", "Reasoning Models"),
        ("bolt.fill", "Fast Responses"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                // Title
                VStack(spacing: 12) {
                    Text("Powerful Models")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Access leading AI models, all running inside secure hardware with verified privacy.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Model carousel
                if !models.isEmpty {
                    modelCarousel
                }

                // Feature grid
                VStack(spacing: 16) {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 12) {
                        ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                            featureCard(icon: feature.icon, label: feature.label)
                                .opacity(showFeatures ? 1 : 0)
                                .offset(y: showFeatures ? 0 : 20)
                                .animation(
                                    .spring(response: 0.4, dampingFraction: 0.8)
                                        .delay(Double(index) * 0.08),
                                    value: showFeatures
                                )
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showFeatures = true
                    }
                }

                Spacer().frame(height: 20)
            }
        }
    }

    private var modelCarousel: some View {
        VStack(spacing: 16) {
            // Scrollable model icons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        modelCard(model: model, isSelected: index == selectedModelIndex)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedModelIndex = index
                                }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }

        
        }
    }

    private func modelCard(model: ModelType, isSelected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isSelected
                        ? Color.primary.opacity(0.12)
                        : Color(UIColor.secondarySystemBackground))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isSelected ? Color.primary.opacity(0.3) : Color.clear,
                                lineWidth: 2
                            )
                    )

                Image(model.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            }
            .scaleEffect(isSelected ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)

            Text(model.displayName)
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
    }

    private func featureCard(icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.1))
                )

            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}
