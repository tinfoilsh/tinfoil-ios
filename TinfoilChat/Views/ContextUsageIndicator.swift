//
//  ContextUsageIndicator.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import SwiftUI

/// Mirrors the webapp's `ContextUsage` shape.
struct ContextUsage {
    let percentage: Double
    let usedTokens: Int
    let limitTokens: Int
}

/// Small ring gauge plus percentage label showing how much of the model's
/// context window the conversation uses. Mirrors the webapp's
/// `ContextUsageIndicator`.
struct ContextUsageIndicator: View {
    let usage: ContextUsage

    private static let ringDiameter: CGFloat = 14
    private static let ringLineWidth: CGFloat = 2

    private var clampedPercentage: Int {
        min(Int(usage.percentage.rounded()), 100)
    }

    private var isNearLimit: Bool {
        clampedPercentage >= Constants.Context.warningThresholdPercent
    }

    private var isFull: Bool {
        clampedPercentage >= 100
    }

    private var ringColor: Color {
        isNearLimit ? .orange : .secondary
    }

    private var accessibilityText: String {
        if isFull {
            return "Context window full (~\(Self.formatTokens(usage.limitTokens)) tokens). Older messages are archived and no longer sent to the model."
        }
        return "Context window \(clampedPercentage)% used (~\(Self.formatTokens(usage.usedTokens)) of \(Self.formatTokens(usage.limitTokens)) tokens)"
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
