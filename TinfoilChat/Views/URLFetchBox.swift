//
//  URLFetchBox.swift
//  TinfoilChat
//
//  Created on 13/03/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI

/// Displays a list of URLs being fetched during web search
struct URLFetchBox: View {
    let urlFetches: [URLFetchState]
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(urlFetches) { fetch in
                URLFetchRow(fetch: fetch, isDarkMode: isDarkMode)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.vertical, 4)
    }
}

/// A single row showing a URL fetch with status
struct URLFetchRow: View {
    let fetch: URLFetchState
    let isDarkMode: Bool

    private var displayHost: String {
        guard let urlObj = URL(string: fetch.url),
              let host = urlObj.host else { return fetch.url }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            if fetch.status == .fetching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else {
                FaviconView(url: fetch.url, isDarkMode: isDarkMode)
                    .opacity(fetch.status == .failed ? 0.4 : 1.0)
            }

            statusText
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusText: some View {
        switch fetch.status {
        case .fetching:
            HStack(spacing: 0) {
                Text("Reading ")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
                Text(displayHost)
                    .font(.system(size: 13))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
        case .completed:
            HStack(spacing: 0) {
                Text("Read ")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
                Text(displayHost)
                    .font(.system(size: 13))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
        case .failed:
            HStack(spacing: 0) {
                Text("Failed to read ")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                Text(displayHost)
                    .font(.system(size: 13))
                    .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                    .strikethrough()
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}
