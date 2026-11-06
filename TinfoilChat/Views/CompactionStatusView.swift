//
//  CompactionStatusView.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import SwiftUI

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
    }
}
