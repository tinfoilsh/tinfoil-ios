//
//  OnboardingView.swift
//  TinfoilChat
//
//  Introduces the founders' letter, conversation privacy, and safeguards.
//

import SwiftUI

// MARK: - Onboarding Flow Container

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow = OnboardingFlow()
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.backgroundPrimary : .white)
                .ignoresSafeArea()
            GridTexture(isDarkMode: colorScheme == .dark)
                .ignoresSafeArea()

            VStack(spacing: Constants.Onboarding.navigationSpacing) {
                GeometryReader { geometry in
                    ScrollView {
                        pageContent
                            .frame(maxWidth: Constants.Onboarding.maximumContentWidth)
                            .padding(.horizontal, Constants.Onboarding.horizontalPadding)
                            .padding(.vertical, Constants.Onboarding.verticalPadding)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }

                VStack(spacing: Constants.Onboarding.navigationSpacing) {
                    HStack(spacing: Constants.Onboarding.dotSpacing) {
                        ForEach(OnboardingFlow.Page.allCases, id: \.self) { page in
                            Capsule()
                                .fill(page == flow.page ? Color.primary : .secondary.opacity(Constants.Onboarding.inactiveDotOpacity))
                                .frame(
                                    width: page == flow.page ? Constants.Onboarding.activeDotWidth : Constants.Onboarding.inactiveDotWidth,
                                    height: Constants.Onboarding.dotHeight
                                )
                        }
                    }
                    .accessibilityHidden(true)

                    Button(action: handleContinue) {
                        Text(flow.continueTitle)
                            .font(.headline)
                            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Constants.Onboarding.navigationPadding)
                            .background(Color.adaptiveAccent, in: RoundedRectangle(cornerRadius: Constants.UI.actionButtonCornerRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(flow.page == .safeguards ? "Finish onboarding" : "Continue onboarding")
                }
                .frame(maxWidth: Constants.Onboarding.maximumContentWidth)
                .padding(.horizontal, Constants.Onboarding.horizontalPadding)

                Text("By continuing, you agree to our [Terms](\(Constants.Legal.termsOfServiceURL.absoluteString)) and have read our [Privacy Policy](\(Constants.Legal.privacyPolicyURL.absoluteString)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .tint(Color.adaptiveAccent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Constants.Onboarding.horizontalPadding)
            }
            .padding(.bottom, Constants.Onboarding.navigationPadding)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch flow.page {
        case .letter:
            OnboardingLetterPage()
        case .privacy:
            OnboardingPrivacyPage(privacyEnabled: $flow.privacyEnabled)
        case .safeguards:
            OnboardingSafeguardsPage()
        }
    }

    private func handleContinue() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Constants.Onboarding.animationDuration)) {
            if flow.advance() {
                onComplete()
            }
        }
    }
}

// MARK: - Screen 1: Letter from the Founders

private struct OnboardingLetterPage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Onboarding.textSpacing) {
            Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                .resizable()
                .scaledToFit()
                .frame(height: Constants.Onboarding.logoHeight)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Tinfoil")

            Image(Constants.Onboarding.bannerAssetName)
                .resizable()
                .scaledToFit()
                .aspectRatio(Constants.Onboarding.bannerAspectRatio, contentMode: .fit)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Text("Why Tinfoil Chat")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(Constants.Onboarding.textSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(Constants.Onboarding.bannerOverlayOpacity))
                        .accessibilityAddTraits(.isHeader)
                }
                .clipShape(RoundedRectangle(cornerRadius: Constants.Onboarding.bannerCornerRadius))

            Text("Tinfoil Chat was built as a sanctuary for thought.")
            Text("At Tinfoil, we believe that AI is the most intimate technology yet created. We see AI as a space to explore, to make mistakes, to think out loud, to reflect with a beautiful and deep intelligence on the other end.")
            Text("This is *your* space to explore ideas in private.")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Screen 2: Privacy

private struct OnboardingPrivacyPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var privacyEnabled: Bool

    var body: some View {
        VStack(spacing: Constants.Onboarding.contentSpacing) {
            Image(systemName: privacyEnabled ? "lock.fill" : "lock.open")
                .font(.system(size: Constants.Onboarding.iconSize))
                .frame(height: Constants.Onboarding.iconAreaHeight)
                .accessibilityHidden(true)

            VStack(spacing: Constants.Onboarding.textSpacing) {
                Text("Private, by Design.")
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)
                Text("Tinfoil Chat runs every conversation inside secure enclaves, giving you access to powerful AI models with verifiable conversation privacy. \(Text("Even Tinfoil cannot access your conversations.").fontWeight(.semibold).foregroundStyle(.primary))")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Constants.Onboarding.navigationSpacing) {
                Button {
                    privacyEnabled.toggle()
                } label: {
                    HStack {
                        if privacyEnabled { Spacer(minLength: .zero) }
                        Circle()
                            .fill(.white)
                            .overlay {
                                if privacyEnabled {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: Constants.Onboarding.checkmarkSize, weight: .bold))
                                        .foregroundStyle(Color.adaptiveAccent)
                                }
                            }
                        if !privacyEnabled { Spacer(minLength: .zero) }
                    }
                    .padding(Constants.Onboarding.togglePadding)
                    .frame(width: Constants.Onboarding.toggleWidth, height: Constants.Onboarding.toggleHeight)
                    .background(privacyEnabled ? Color.adaptiveAccent : .red, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle privacy")
                .accessibilityValue(privacyEnabled ? "Private" : "Enable Privacy")
                .animation(reduceMotion ? nil : .easeInOut(duration: Constants.Onboarding.animationDuration), value: privacyEnabled)

                Text(privacyEnabled ? "Private" : "Enable Privacy")
                    .fontWeight(.semibold)
                    .foregroundStyle(privacyEnabled ? Color.adaptiveAccent : .red)
            }
        }
    }
}

// MARK: - Screen 3: Safeguards

private struct OnboardingSafeguardsPage: View {
    var body: some View {
        VStack(spacing: Constants.Onboarding.contentSpacing) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: Constants.Onboarding.iconSize))
                .frame(height: Constants.Onboarding.iconAreaHeight)
                .accessibilityHidden(true)

            VStack(spacing: Constants.Onboarding.textSpacing) {
                Text("Tending the Garden")
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)
                Text("Privacy-preserving safeguards review the AI responses in this chat. The safeguards run inside secure enclaves at inference time, always keeping your conversations private. \(Text("Tinfoil cannot see the nature of the violation or conversation content.").fontWeight(.semibold).foregroundStyle(.primary))")
                    .foregroundStyle(.secondary)

                Link(destination: Constants.Safeguards.infoURL) {
                    Text("Learn more about safeguards")
                        .font(.subheadline)
                        .underline()
                }
                .tint(Color.adaptiveAccent)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
