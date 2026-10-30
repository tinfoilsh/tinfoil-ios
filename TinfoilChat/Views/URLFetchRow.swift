//
//  URLFetchRow.swift
//  TinfoilChat
//
//  Created on 13/03/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI

/// A single link read inside an open link-read step
struct URLFetchRow: View {
    let fetch: URLFetchState
    let isDarkMode: Bool

    private var displayHost: String {
        guard let urlObj = URL(string: fetch.url),
              let host = urlObj.host else { return fetch.url }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        Button(action: openURL) {
            HStack(spacing: 10) {
                FaviconView(url: fetch.url, isDarkMode: isDarkMode)
                    .opacity(fetch.status == .failed || fetch.status == .blocked ? 0.4 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayHost)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
                        .lineLimit(1)

                    Text(statusLabel)
                        .font(.system(size: 12))
                        .foregroundColor(statusColor)
                }

                Spacer()

                if fetch.status == .completed {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                }
            }
            .padding(.vertical, Constants.UI.WorkSteps.linkRowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(fetch.status != .completed)
    }

    private var statusLabel: String {
        switch fetch.status {
        case .fetching: return "Reading..."
        case .completed: return "Read"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    private var statusColor: Color {
        switch fetch.status {
        case .fetching: return isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5)
        case .completed: return isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5)
        case .failed: return .red.opacity(0.7)
        case .blocked: return .orange.opacity(0.7)
        }
    }

    private func openURL() {
        LinkOpener.open(fetch.url)
    }
}
