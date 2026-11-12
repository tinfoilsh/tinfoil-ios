//
//  ContextUsageIndicator.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import SwiftUI

/// Mirrors the webapp's `ContextUsage` shape.
struct ContextUsage: Equatable {
    let percentage: Double
    let usedTokens: Int
    let limitTokens: Int
}

/// Small ring gauge plus percentage label showing how much of the model's
/// context window the conversation uses. Mirrors the webapp's
/// `ContextUsageIndicator`.
struct ContextUsageIndicator: View {
    let usage: ContextUsage
    /// The chat service summarizes the earlier messages of a chat that
    /// fills its context, rather than refusing its next turn.
    let compacts: Bool

    private static let ringDiameter: CGFloat = 14
    private static let ringLineWidth: CGFloat = 2

    private var clampedPercentage: Int {
        min(Int(usage.percentage.rounded()), 100)
    }

    private var isNearLimit: Bool {
        clampedPercentage >= Constants.Context.warningThresholdPercent
    }

    private var ringColor: Color {
        isNearLimit ? .orange : .secondary
    }

    private var accessibilityText: String {
        Self.description(of: usage, compacts: compacts)
    }

    /// How much of the context window the chat uses, as VoiceOver reads the
    /// indicator.
    static func description(of usage: ContextUsage, compacts: Bool) -> String {
        let percentage = min(Int(usage.percentage.rounded()), 100)
        if percentage >= 100, compacts {
            return "Context window full (~\(formatTokens(usage.limitTokens)) tokens). Earlier messages will be summarized to make room."
        }
        if percentage >= 100 {
            return "Context window full (~\(formatTokens(usage.limitTokens)) tokens). Older messages are archived and no longer sent to the model."
        }
        return "Context window \(percentage)% used (~\(formatTokens(usage.usedTokens)) of \(formatTokens(usage.limitTokens)) tokens)"
    }

    /// The context popover's title: how full the window is.
    static func headline(of usage: ContextUsage) -> String {
        let percentage = min(Int(usage.percentage.rounded()), 100)
        return percentage >= 100 ? "Context window full" : "Context window \(percentage)% used"
    }

    /// The tokens the chat uses, on a line of their own under the popover's
    /// title.
    static func tokensUsed(of usage: ContextUsage) -> String {
        "~\(formatTokens(usage.usedTokens)) out of \(formatTokens(usage.limitTokens)) tokens"
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: Self.ringLineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(clampedPercentage) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)

            Text("\(clampedPercentage)%")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundColor(ringColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return "\(Int((Double(tokens) / 1000).rounded()))k"
        }
        return "\(tokens)"
    }
}

/// What the context row opens while the chat service compacts chats on
/// request: how much of the window the chat uses, and a button that
/// compacts it. Mirrors the webapp's context popover.
struct ContextCompactionPopover: View {
    let usage: ContextUsage
    let compacts: Bool
    /// Compacting summarizes the latest exchange too.
    let compactsLatest: Bool
    let canCompact: Bool
    let compacting: Bool
    let onCompact: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Context.popoverSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ContextUsageIndicator.headline(of: usage))
                    .font(.subheadline.weight(.semibold))
                Text(ContextUsageIndicator.tokensUsed(of: usage))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ContextUsageIndicator.description(of: usage, compacts: compacts))
            Text(compactsLatest ? Constants.Context.compactLatestExplanation : Constants.Context.compactExplanation)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onCompact) {
                HStack(spacing: 8) {
                    if compacting {
                        ProgressView()
                    } else {
                        Image(systemName: Constants.Context.compactSystemImage)
                    }
                    Text(compacting ? Constants.Context.compactingLabel : Constants.Context.compactLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canCompact)
            if !canCompact, !compacting {
                Text(Constants.Context.nothingToCompactNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(Constants.Context.popoverPadding)
        .frame(width: Constants.Context.popoverWidth)
    }
}
