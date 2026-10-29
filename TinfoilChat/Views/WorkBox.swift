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

extension WorkStep {
    /// What a finished thought says; one the chat service timed no duration
    /// for shows no time.
    static func thoughtLabel(duration: Double?) -> String {
        guard let duration else { return "Thought" }
        return "Thought for \(ElapsedTime.label(duration))"
    }
}

/// Whole-second durations as work steps show them, both while they run and
/// once they finish: "8s", "3m 33s", "1h 4m".
enum ElapsedTime {
    private static let secondsPerMinute = 60
    private static let secondsPerHour = 3_600

    static func label(_ seconds: Double) -> String {
        let time = parts(seconds)
        if time.hours > 0 { return "\(time.hours)h \(time.minutes)m" }
        if time.minutes > 0 { return "\(time.minutes)m \(time.seconds)s" }
        return "\(time.seconds)s"
    }

    /// The same duration as VoiceOver says it, such as "3 minutes, 33 seconds".
    static func spokenLabel(_ seconds: Double) -> String {
        let time = parts(seconds)
        let components = time.hours > 0
            ? DateComponents(hour: time.hours, minute: time.minutes)
            : time.minutes > 0
                ? DateComponents(minute: time.minutes, second: time.seconds)
                : DateComponents(second: time.seconds)
        return spokenFormatter.string(from: components) ?? label(seconds)
    }

    private static let spokenFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter
    }()

    /// Whole elapsed seconds, as a clock counts them, never below zero.
    private static func parts(_ seconds: Double) -> (hours: Int, minutes: Int, seconds: Int) {
        let whole = seconds.isFinite ? Int(max(0, seconds)) : 0
        return (whole / secondsPerHour, whole % secondsPerHour / secondsPerMinute, whole % secondsPerMinute)
    }
}

/// A consecutive run of trace steps (thinking / searches / fetches) with
/// no visible answer text or GenUI widget in between. Rendered collapsed
/// as a single row naming what the run did.
struct WorkRun: Equatable {
    let steps: [WorkStep]

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

    /// Names what the run did, each kind of action once in the order the run
    /// first took it: "Thought, searched the web, and read 3 pages".
    var summaryLabel: String {
        var actions: [String] = []
        var hasThought = false
        var hasSearched = false
        var hasRead = false
        for step in steps {
            switch step {
            case .thinking where !hasThought:
                hasThought = true
                actions.append("thought")
            case .webSearches where !hasSearched:
                hasSearched = true
                actions.append("searched the web")
            case .urlFetches where !hasRead:
                hasRead = true
                actions.append(readAction)
            default:
                break
            }
        }
        let sentence: String
        switch actions.count {
        case 0:
            return "Worked"
        case 1:
            sentence = actions[0]
        case 2:
            sentence = "\(actions[0]) and \(actions[1])"
        default:
            sentence = actions.dropLast().joined(separator: ", ") + ", and \(actions[actions.count - 1])"
        }
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// The pages the run read, across all its link reads; a run whose every
    /// read failed tried to read them.
    private var readAction: String {
        let fetches = steps.flatMap { step -> [URLFetchState] in
            if case .urlFetches(let group) = step { return group }
            return []
        }
        let read = fetches.filter { $0.status == .completed }.count
        if read > 0 { return read == 1 ? "read a page" : "read \(read) pages" }
        return fetches.count == 1 ? "tried to read a page" : "tried to read \(fetches.count) pages"
    }
}

/// Collapsed inline row for a `WorkRun`. While the run is active it shows
/// the current activity (thinking summary, in-flight search, link reads);
/// once settled it names what the run did. Tapping opens the steps sheet.
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
            // A scroll view rather than a List: a List row resizes after an
            // expanded thought renders, so the thought overlaps other rows.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                        WorkStepSection(step: step, isDarkMode: isDarkMode)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        return WorkStep.thoughtLabel(duration: duration)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVStack(alignment: .leading, spacing: 0) {
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
