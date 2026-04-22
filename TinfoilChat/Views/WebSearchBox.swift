//
//  WebSearchBox.swift
//  TinfoilChat
//
//  Created on 02/02/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI

/// Inline row showing web search status; tapping opens sources sheet.
/// When `groupSize > 1`, the row summarizes an adjacent run of searches
/// (e.g. "Searched the web on 4 queries") so the chat isn't vertically
/// polluted by one pill per search.
struct WebSearchBox: View {
    let webSearchState: WebSearchState
    let isDarkMode: Bool
    let webSearchSummary: String?
    let groupSize: Int
    let onTap: () -> Void

    init(
        webSearchState: WebSearchState,
        isDarkMode: Bool,
        webSearchSummary: String?,
        groupSize: Int = 1,
        onTap: @escaping () -> Void
    ) {
        self.webSearchState = webSearchState
        self.isDarkMode = isDarkMode
        self.webSearchSummary = webSearchSummary
        self.groupSize = groupSize
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                headerContent
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoHighlightButtonStyle())
        .disabled(!isInteractive)
    }

    private var isGroup: Bool { groupSize > 1 }

    private var showsChevron: Bool {
        guard webSearchState.status != .searching else { return false }
        return isGroup || !webSearchState.sources.isEmpty
    }

    private var isInteractive: Bool {
        guard webSearchState.status != .searching else { return false }
        return isGroup || !webSearchState.sources.isEmpty
    }

    @ViewBuilder
    private var headerContent: some View {
        switch webSearchState.status {
        case .searching:
            HStack(spacing: 8) {
                if isGroup {
                    Text("Searching the web on \(groupSize) queries")
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.8))
                } else if let summary = webSearchSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let query = webSearchState.query {
                    Text("Searching the web: \(query)")
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Searching the web")
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white : .black.opacity(0.8))
                }
                SearchingDotsView(isDarkMode: isDarkMode)
            }

        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
                    .font(.system(size: 14))

                if isGroup {
                    Text("Searched the web on \(groupSize) quer\(groupSize == 1 ? "y" : "ies")")
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
                    if !webSearchState.sources.isEmpty {
                        sourceFavicons
                    }
                } else if webSearchState.sources.isEmpty {
                    Text("Web search completed")
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
                } else {
                    Text("\(webSearchState.sources.count) source\(webSearchState.sources.count == 1 ? "" : "s") found")
                        .font(.subheadline)
                        .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))

                    sourceFavicons
                }
            }

        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
                Text("Search failed")
                    .font(.subheadline)
                    .foregroundColor(.red.opacity(0.8))
            }

        case .blocked:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                Text(webSearchState.reason ?? "Search blocked")
                    .font(.subheadline)
                    .foregroundColor(.orange.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var sourceFavicons: some View {
        HStack(spacing: -4) {
            ForEach(Array(webSearchState.sources.prefix(4).enumerated()), id: \.element.id) { index, source in
                FaviconView(url: source.url, isDarkMode: isDarkMode)
                    .zIndex(Double(4 - index))
            }
            if webSearchState.sources.count > 4 {
                Text("+\(webSearchState.sources.count - 4)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.6) : .black.opacity(0.6))
                    .padding(.leading, 6)
            }
        }
    }

}

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

/// Favicon view that displays a website icon
struct FaviconView: View {
    let url: String
    let isDarkMode: Bool

    private var faviconURL: URL? {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }

    var body: some View {
        AsyncImage(url: faviconURL) { phase in
            switch phase {
            case .empty:
                placeholderIcon
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failure:
                placeholderIcon
            @unknown default:
                placeholderIcon
            }
        }
        .frame(width: 16, height: 16)
        .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var placeholderIcon: some View {
        Image(systemName: "globe")
            .font(.system(size: 10))
            .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5))
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
        guard let url = URL(string: source.url) else { return }
        UIApplication.shared.open(url)
    }
}

/// Sheet listing every query in a grouped run of web searches, each
/// expandable to reveal its individual sources.
struct WebSearchQueriesSheetView: View {
    let instances: [WebSearchInstance]
    let isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var expandedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(instances) { instance in
                    WebSearchQueryRow(
                        instance: instance,
                        isDarkMode: isDarkMode,
                        isExpanded: expandedIds.contains(instance.id),
                        onToggle: { toggle(instance.id) }
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }

    private func toggle(_ id: String) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
        }
    }
}

private struct WebSearchQueryRow: View {
    let instance: WebSearchInstance
    let isDarkMode: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    private var canExpand: Bool { !(instance.sources?.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { if canExpand { onToggle() } }) {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instance.query ?? "Web search")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(statusLabel)
                            .font(.system(size: 12))
                            .foregroundColor(statusColor)
                    }
                    Spacer()
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canExpand)

            if isExpanded, let sources = instance.sources, !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources) { source in
                        SourceRowView(source: source, isDarkMode: isDarkMode)
                    }
                }
                .padding(.leading, 26)
            }
        }
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

    private var statusLabel: String {
        switch instance.status {
        case .searching: return "Searching..."
        case .completed:
            let count = instance.sources?.count ?? 0
            return count == 0 ? "Completed" : "\(count) source\(count == 1 ? "" : "s")"
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
