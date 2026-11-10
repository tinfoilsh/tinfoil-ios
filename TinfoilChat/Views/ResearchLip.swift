//
//  ResearchLip.swift
//  TinfoilChat
//

import SwiftUI

private enum ResearchLipLayout {
    /// How far the lip sits from the bubble's trailing edge, clear of its
    /// rounded corner.
    static let inset: CGFloat = 16
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let labelSpacing: CGFloat = 4
    static let darkForegroundOpacity = 0.6
    static let lightForegroundOpacity = 0.55
}

/// What the lip says, at the size the lip takes.
private struct ResearchLipLabel: View {
    var body: some View {
        HStack(spacing: ResearchLipLayout.labelSpacing) {
            Image(systemName: Constants.Research.systemImage)
            Text(Constants.Research.label)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, ResearchLipLayout.horizontalPadding)
        .padding(.vertical, ResearchLipLayout.verticalPadding)
    }
}

/// The tab on the top edge of a question's bubble saying it asked for deep
/// research.
private struct ResearchLip: View {
    let isDarkMode: Bool

    var body: some View {
        ResearchLipLabel()
            .foregroundStyle(
                isDarkMode
                    ? Color.white.opacity(ResearchLipLayout.darkForegroundOpacity)
                    : Color.black.opacity(ResearchLipLayout.lightForegroundOpacity)
            )
            .background {
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: ResearchLipLayout.cornerRadius,
                    topTrailingRadius: ResearchLipLayout.cornerRadius
                )
                if #available(iOS 26, *) {
                    shape.fill(.thickMaterial)
                } else {
                    shape.fill(Color.userMessageBackground(isDarkMode: isDarkMode))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Constants.Research.questionAccessibilityLabel)
    }
}

extension View {
    /// Keeps a bubble wide enough for the research lip on it, so the lip
    /// never overhangs the bubble's leading corner. Applies inside the
    /// bubble's background.
    @ViewBuilder
    func fitsResearchLip(_ isShown: Bool) -> some View {
        if isShown {
            ZStack(alignment: .topLeading) {
                ResearchLipLabel()
                    .padding(.horizontal, ResearchLipLayout.inset)
                    .hidden()
                    .frame(height: 0)
                self
            }
        } else {
            self
        }
    }

    /// Sets the research lip on the top edge of a bubble, near its trailing
    /// corner.
    @ViewBuilder
    func researchLip(_ isShown: Bool, isDarkMode: Bool) -> some View {
        if isShown {
            VStack(alignment: .trailing, spacing: 0) {
                ResearchLip(isDarkMode: isDarkMode)
                    .padding(.trailing, ResearchLipLayout.inset)
                self
            }
        } else {
            self
        }
    }
}
