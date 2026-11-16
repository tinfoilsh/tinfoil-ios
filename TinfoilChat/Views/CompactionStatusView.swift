//
//  CompactionStatusView.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import SwiftUI
import TinfoilIcons

/// Says the open chat is being compacted, above the composer and the
/// message queued behind the compaction, which sends once it ends. Mirrors
/// the webapp's CompactionStatus.
struct CompactionStatusView: View {
    let isDarkMode: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(Constants.Context.compactingStatusTitle)
                    .font(.system(size: 14, weight: .medium))
                Text(Constants.Context.compactingStatusDetail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.chatSurface(isDarkMode: isDarkMode))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        // VoiceOver hears every compaction start, also one a turn makes
        // inside a reply it already announced.
        .onAppear { AccessibilityAnnouncer.announce(Constants.Accessibility.compactingChat) }
    }
}

/// Says the open chat was just compacted, where the status of its
/// compaction showed: the chat's marker sits above earlier messages, often
/// out of view. Mirrors the webapp's CompactedNotice.
struct CompactedNoticeView: View {
    let messageCount: Int
    let isDarkMode: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(tinfoil: .checkmarkCircle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(Constants.Context.compactedNoticeTitle)
                    .font(.system(size: 14, weight: .medium))
                Text("Summarized \(messageCount) earlier message\(messageCount == 1 ? "" : "s"). The assistant now reads the summary in their place.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(tinfoil: .xmark)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle().inset(by: -12))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.chatSurface(isDarkMode: isDarkMode))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}
