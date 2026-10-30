//
//  WebSearchRows.swift
//  TinfoilChat
//
//  Created on 02/02/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI

/// Animated dots for searching state
struct SearchingDotsView: View {
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .modifier(PulsingAnimation(delay: 0.15 * Double(index)))
            }
        }
        .foregroundColor(isDarkMode ? .white : .black.opacity(0.8))
    }
}

/// Raw favicon image fetched through the attested metadata enclave.
/// Owns its async load + state so it can be dropped into any parent
/// (with its own frame, background, and clip shape) without each
/// caller duplicating the loader.
struct FaviconImage: View {
    let url: String
    let placeholderColor: Color
    let placeholderFontSize: CGFloat

    @State private var iconImage: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image = iconImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loadFailed {
                Image(systemName: "globe")
                    .font(.system(size: placeholderFontSize))
                    .foregroundColor(placeholderColor)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            iconImage = nil
            loadFailed = false
            do {
                let bytes = try await LinkMetadataService.shared.favicon(for: url)
                // The shared in-flight fetch doesn't observe this
                // task's cancellation, so a superseded task can reach
                // this point; bail before stomping the new task's state.
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if let image = UIImage(data: bytes) {
                        iconImage = image
                    } else {
                        loadFailed = true
                    }
                }
            } catch is CancellationError {
                // The task was superseded (url changed or view went
                // away). The new task will reset state itself; don't
                // surface a failure for an expected cancel.
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { loadFailed = true }
            }
        }
    }
}

/// Favicon view that displays a website icon. The icon bytes are
/// fetched through the attested metadata enclave so the device never
/// touches an external icon host directly.
struct FaviconView: View {
    let url: String
    let isDarkMode: Bool

    var body: some View {
        FaviconImage(
            url: url,
            placeholderColor: isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5),
            placeholderFontSize: 10
        )
        .frame(width: 16, height: 16)
        .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// Row view for a single source
struct SourceRowView: View {
    let source: WebSearchSource
    let isDarkMode: Bool

    private var displayHost: String {
        guard let url = URL(string: source.url),
              let host = url.host else { return source.url }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        Button(action: openURL) {
            HStack(spacing: 10) {
                FaviconView(url: source.url, isDarkMode: isDarkMode)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(displayHost)
                        .font(.system(size: 11))
                        .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func openURL() {
        LinkOpener.open(source.url)
    }
}

/// Flat row for a single search inside an open search step: the query
/// stands as the heading with its sources listed directly beneath (when
/// attributed). Mirrors the webapp's grouped-search expansion.
struct WebSearchQueryRow: View {
    let instance: WebSearchInstance
    let isDarkMode: Bool

    private var sources: [WebSearchSource] {
        instance.sources ?? []
    }

    private var displayQuery: String {
        if let query = instance.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return query
        }
        return "Web search"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayQuery)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = statusSubtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(statusColor)
                    }
                }
                Spacer(minLength: 0)
            }

            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources) { source in
                        SourceRowView(source: source, isDarkMode: isDarkMode)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, Constants.UI.WorkSteps.searchRowPadding)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch instance.status {
        case .searching:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "globe")
                .font(.system(size: 13))
                .foregroundColor(isDarkMode ? .white.opacity(0.6) : .black.opacity(0.5))
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.red.opacity(0.8))
                .frame(width: 16, height: 16)
        case .blocked:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(.orange.opacity(0.8))
                .frame(width: 16, height: 16)
        }
    }

    private var statusSubtitle: String? {
        switch instance.status {
        case .searching: return "Searching…"
        case .completed:
            let count = sources.count
            return count > 0 ? "\(count) source\(count == 1 ? "" : "s")" : nil
        case .failed: return "Failed"
        case .blocked: return instance.reason ?? "Blocked"
        }
    }

    private var statusColor: Color {
        switch instance.status {
        case .searching, .completed:
            return isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5)
        case .failed: return .red.opacity(0.7)
        case .blocked: return .orange.opacity(0.7)
        }
    }
}
