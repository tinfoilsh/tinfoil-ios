//
//  WorkBox.swift
//  TinfoilChat
//
//  Created on 09/10/26.
//  Copyright © 2026 Tinfoil. All rights reserved.

import SwiftUI

/// One step inside a run of agentic work: a thinking round, an adjacent
/// group of web searches, or an adjacent group of URL fetches.
enum WorkStep: Equatable {
    case thinking(content: String, isThinking: Bool, duration: Double?, startedAt: Double?, endedAt: Double?)
    case webSearches([WebSearchInstance])
    case urlFetches([URLFetchState])

    /// Stable within a run; combine with the run's start index for a
    /// globally unique row id.
    var id: String {
        switch self {
        case .thinking:
            return "thinking"
        case .webSearches(let group):
            return "searches:\(group.first?.id ?? "")"
        case .urlFetches(let group):
            return "fetches:\(group.first?.id ?? "")"
        }
    }

    var isInFlight: Bool {
        switch self {
        case .thinking(_, let isThinking, _, _, _):
            return isThinking
        case .webSearches(let group):
            return group.contains { $0.status == .searching }
        case .urlFetches(let group):
            return group.contains { $0.status == .fetching }
        }
    }
}

/// What the agent is doing right now, derived from the last step of an
/// active run. Drives the collapsed row's header while streaming.
enum WorkActivity: Equatable {
    case thinking
    case searching(query: String?)
    case reading(count: Int)
    /// Every step has settled but the stream hasn't produced answer text yet.
    case idle
}

/// A consecutive run of trace steps (thinking / searches / fetches) with
/// no visible answer text or GenUI widget in between. Rendered collapsed
/// as a single "Worked for Ns" row.
struct WorkRun: Equatable {
    let steps: [WorkStep]

    /// Wall-clock span from the stamps recorded while streaming. Falls back
    /// to summed thinking durations for messages saved before stamps
    /// existed; nil when neither is available.
    var durationSeconds: Double? {
        var start: Double = .infinity
        var end: Double = -.infinity
        var thinkingTotal: Double = 0

        func note(startedAt: Double?, endedAt: Double?) {
            guard let startedAt else { return }
            start = min(start, startedAt)
            end = max(end, endedAt ?? startedAt)
        }

        for step in steps {
            switch step {
            case .thinking(_, _, let duration, let startedAt, let endedAt):
                note(startedAt: startedAt, endedAt: endedAt)
                thinkingTotal += duration ?? 0
            case .webSearches(let group):
                for search in group { note(startedAt: search.startedAt, endedAt: search.endedAt) }
            case .urlFetches(let group):
                for fetch in group { note(startedAt: fetch.startedAt, endedAt: fetch.endedAt) }
            }
        }

        if start.isFinite { return max(0, (end - start) / 1000) }
        return thinkingTotal > 0 ? thinkingTotal : nil
    }

    var liveActivity: WorkActivity {
        guard let last = steps.last, last.isInFlight else { return .idle }
        switch last {
        case .thinking:
            return .thinking
        case .webSearches(let group):
            return .searching(query: group.last(where: { $0.status == .searching })?.query)
        case .urlFetches(let group):
            return .reading(count: group.count)
        }
    }

    /// "Worked for 4.7s" under a minute, "Worked for 1m 24s" otherwise.
    static func formatDuration(_ seconds: Double) -> String {
        let rounded = (seconds * 10).rounded() / 10
        if rounded < 60 {
            return String(format: "%.1fs", rounded)
        }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }

    var summaryLabel: String {
        if let seconds = durationSeconds {
            return "Worked for \(Self.formatDuration(seconds))"
        }
        return "Worked through \(steps.count) step\(steps.count == 1 ? "" : "s")"
    }
}

/// Collapsed inline row for a `WorkRun`. While the run is active it shows
/// the current activity (thinking summary, in-flight search, link reads);
/// once settled it reads "Worked for Ns". Tapping opens the steps sheet.
struct WorkBox: View {
    let run: WorkRun
    let isActive: Bool
    let isDarkMode: Bool
    let thinkingSummary: String?
    let webSearchSummary: String?
    let onTap: () -> Void

    private var activity: WorkActivity? {
        isActive ? run.liveActivity : nil
    }

    private var primaryColor: Color {
        isDarkMode ? .white : .black.opacity(0.8)
    }

    private var mutedColor: Color {
        isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6)
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                headerContent
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoHighlightButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows the steps")
    }

    private var accessibilityLabel: String {
        switch activity {
        case .thinking:
            if let summary = thinkingSummary, !summary.isEmpty { return summary }
            return "Thinking"
        case .searching(let query):
            return query.map { "Searching the web: \($0)" } ?? "Searching the web"
        case .reading(let count):
            return "Reading \(count) link\(count == 1 ? "" : "s")"
        case .idle:
            return "Working"
        case nil:
            return run.summaryLabel
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        switch activity {
        case .thinking:
            if let summary = thinkingSummary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(TextShimmerAnimation())
            } else {
                workingLabel("Thinking")
            }

        case .searching(let query):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                spinner
                if let summary = webSearchSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(primaryColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let query {
                    Text("Searching the web: \(query)")
                        .font(.subheadline)
                        .foregroundColor(primaryColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Searching the web")
                        .font(.subheadline)
                        .foregroundColor(primaryColor)
                }
            }

        case .reading(let count):
            HStack(spacing: 8) {
                spinner
                Text("Reading \(count) link\(count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(primaryColor)
            }

        case .idle:
            workingLabel("Working")

        case nil:
            Text(run.summaryLabel)
                .font(.subheadline)
                .foregroundColor(mutedColor)
        }
    }

    private var spinner: some View {
        ProgressView()
            .scaleEffect(0.6)
            .frame(width: 14, height: 14)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
    }

    private func workingLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundColor(primaryColor)
            InlineLoadingDotsView(isDarkMode: isDarkMode)
        }
        .modifier(TextShimmerAnimation())
    }
}

/// Sheet listing every step of a work run in order. Thoughts expand in
/// place; searches and link reads list their queries / pages inline using
/// the same rows as their standalone sheets.
struct WorkStepsSheetView: View {
    let run: WorkRun
    let isDarkMode: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                    WorkStepSection(step: step, isDarkMode: isDarkMode)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle(run.summaryLabel)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}

private struct WorkStepSection: View {
    let step: WorkStep
    let isDarkMode: Bool

    var body: some View {
        switch step {
        case .thinking(let content, let isThinking, let duration, _, _):
            WorkThinkingStepView(
                content: content,
                isThinking: isThinking,
                duration: duration,
                isDarkMode: isDarkMode
            )
        case .webSearches(let group):
            VStack(alignment: .leading, spacing: 4) {
                stepHeading(
                    icon: "globe",
                    text: group.contains(where: { $0.status == .searching })
                        ? "Searching the web on \(group.count) quer\(group.count == 1 ? "y" : "ies")"
                        : "Searched the web on \(group.count) quer\(group.count == 1 ? "y" : "ies")"
                )
                ForEach(group) { instance in
                    WebSearchQueryRow(instance: instance, isDarkMode: isDarkMode)
                        .padding(.leading, 22)
                }
            }
            .padding(.vertical, 6)
        case .urlFetches(let group):
            let completed = group.filter { $0.status == .completed }.count
            VStack(alignment: .leading, spacing: 4) {
                stepHeading(
                    icon: "link",
                    text: group.contains(where: { $0.status == .fetching })
                        ? "Reading \(group.count) link\(group.count == 1 ? "" : "s")"
                        : "Read \(completed) link\(completed == 1 ? "" : "s")"
                )
                ForEach(group) { fetch in
                    URLFetchSheetRow(fetch: fetch, isDarkMode: isDarkMode)
                        .padding(.leading, 22)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func stepHeading(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
        }
    }
}

/// A thinking step inside the work sheet: a "Thought for Ns" heading that
/// expands to the reasoning text, chunked lazily so a long thought never
/// lays out as one giant Text.
private struct WorkThinkingStepView: View {
    let content: String
    let isThinking: Bool
    let duration: Double?
    let isDarkMode: Bool

    @State private var isExpanded = false
    @State private var chunks: [ThinkingChunk]? = nil

    private var heading: String {
        if isThinking { return "Thinking" }
        if let duration { return "Thought for \(String(format: "%.1f", duration))s" }
        return "Thought"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if let chunks {
                    ForEach(chunks) { chunk in
                        ThinkingChunkView(chunk: chunk, isDarkMode: isDarkMode)
                            .equatable()
                    }
                } else if !content.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .task(id: isExpanded) {
                guard isExpanded, chunks == nil, !content.isEmpty else { return }
                let text = content
                chunks = await Task.detached {
                    ThinkingTextChunker.chunk(text)
                }.value
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 14))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
                    .accessibilityHidden(true)
                Text(heading)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isDarkMode ? .white : .black.opacity(0.85))
            }
        }
        .tint(isDarkMode ? .white.opacity(0.6) : .black.opacity(0.5))
        .padding(.vertical, 6)
    }
}
