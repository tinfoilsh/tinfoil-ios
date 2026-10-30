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
    case thinking(content: String, isThinking: Bool, duration: Double?, startedAt: Double?)
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
        case .thinking(_, let isThinking, _, _):
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

/// What a work header says, and how it reads.
struct WorkLabel: Equatable {
    enum Tone: Equatable {
        case live
        case settled
        case failed
        case blocked
    }

    let text: String
    let tone: Tone
    /// A thought or run still working shimmers.
    var shimmers = false
}

extension WorkStep {
    /// What a finished thought says; one the chat service timed no duration
    /// for shows no time.
    static func thoughtLabel(duration: Double?) -> String {
        guard let duration else { return "Thought" }
        return "Thought for \(ElapsedTime.label(duration))"
    }

    /// When the step started, in epoch milliseconds: the earliest stamp of
    /// its parts.
    var startedAt: Double? {
        switch self {
        case .thinking(_, _, _, let startedAt):
            return startedAt
        case .webSearches(let group):
            return group.compactMap(\.startedAt).min()
        case .urlFetches(let group):
            return group.compactMap(\.startedAt).min()
        }
    }

    /// What the step's details hold, as VoiceOver names them.
    var detailsName: String {
        switch self {
        case .thinking: return "reasoning"
        case .webSearches: return "searches"
        case .urlFetches: return "links"
        }
    }

    /// What the step's header says: what it is doing while it runs, and
    /// what it did once it settles. The summaries are the chat service's
    /// live description of a thought or search.
    func label(isActive: Bool, thinkingSummary: String? = nil, webSearchSummary: String? = nil) -> WorkLabel {
        switch self {
        case .thinking(_, _, let duration, _):
            guard isActive else { return WorkLabel(text: Self.thoughtLabel(duration: duration), tone: .settled) }
            return WorkLabel(text: Self.nonEmpty(thinkingSummary) ?? "Thinking", tone: .live, shimmers: true)
        case .webSearches(let group):
            if isActive {
                if group.count > 1 {
                    return WorkLabel(text: "Searching the web on \(group.count) queries", tone: .live)
                }
                return WorkLabel(text: Self.searchingLabel(summary: webSearchSummary, query: group.first?.query), tone: .live)
            }
            switch Self.status(of: group) {
            case .failed:
                return WorkLabel(text: "Search failed", tone: .failed)
            case .blocked:
                return WorkLabel(text: group.compactMap(\.reason).first ?? "Search blocked", tone: .blocked)
            case .searching, .completed:
                return WorkLabel(text: "Searched the web on \(group.count) quer\(group.count == 1 ? "y" : "ies")", tone: .settled)
            }
        case .urlFetches(let group):
            if isActive {
                return WorkLabel(text: "Reading \(group.count) link\(group.count == 1 ? "" : "s")", tone: .live)
            }
            let read = group.filter { $0.status == .completed }.count
            if read == 0 {
                return WorkLabel(text: "Tried to read \(group.count) link\(group.count == 1 ? "" : "s")", tone: .settled)
            }
            return WorkLabel(text: "Read \(read) link\(read == 1 ? "" : "s")", tone: .settled)
        }
    }

    static func searchingLabel(summary: String?, query: String?) -> String {
        if let summary = nonEmpty(summary) { return summary }
        if let query { return "Searching the web: \(query)" }
        return "Searching the web"
    }

    /// The status a group of searches shows as one: searching while any
    /// runs, then failed, then blocked, and otherwise completed.
    private static func status(of group: [WebSearchInstance]) -> WebSearchStatus {
        let statuses = group.map(\.status)
        for status in [WebSearchStatus.searching, .failed, .blocked] where statuses.contains(status) {
            return status
        }
        return .completed
    }

    fileprivate static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// Which work rows of a message are open. It belongs to the message's row
/// in the table rather than to its view, so a row still shows what it showed
/// when the table hosts the message in another cell.
final class WorkStepExpansion: ObservableObject {
    @Published private(set) var expandedRows: Set<String> = []

    func isExpanded(_ rowId: String) -> Bool {
        expandedRows.contains(rowId)
    }

    func toggle(_ rowId: String) {
        if expandedRows.remove(rowId) == nil {
            expandedRows.insert(rowId)
        }
    }

    /// Opens or closes a step standing alone, and with it the same step as
    /// the first of the run it may grow into, so what the step shows stays
    /// open when more steps join it.
    func toggleLoneStep(_ step: WorkStep, rowId: String) {
        let firstStepRowId = WorkRun.stepRowId(step, at: 0, in: rowId)
        if expandedRows.remove(rowId) == nil {
            expandedRows.insert(rowId)
            expandedRows.insert(firstStepRowId)
        } else {
            expandedRows.remove(firstStepRowId)
        }
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

    /// When the run started, in epoch milliseconds: its earliest stamp.
    var startedAt: Double? {
        steps.compactMap(\.startedAt).min()
    }

    /// The row id a step of the run is opened under. A run can hold more
    /// than one step of a kind, so its position tells them apart.
    static func stepRowId(_ step: WorkStep, at index: Int, in runRowId: String) -> String {
        "\(runRowId)/\(index):\(step.id)"
    }

    /// What the run's header says: what it is doing now while it is live,
    /// and what it did once it settles.
    func label(isActive: Bool, thinkingSummary: String? = nil, webSearchSummary: String? = nil) -> WorkLabel {
        guard isActive else { return WorkLabel(text: summaryLabel, tone: .settled) }
        switch liveActivity {
        case .thinking:
            return WorkLabel(text: WorkStep.nonEmpty(thinkingSummary) ?? "Thinking", tone: .live, shimmers: true)
        case .searching(let query):
            return WorkLabel(text: WorkStep.searchingLabel(summary: webSearchSummary, query: query), tone: .live)
        case .reading(let count):
            return WorkLabel(text: "Reading \(count) link\(count == 1 ? "" : "s")", tone: .live)
        case .idle:
            return WorkLabel(text: "Working", tone: .live, shimmers: true)
        }
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

    /// Names what the run did, each kind of action once in the order the run
    /// first took it: "Thought, searched the web, and read 3 links".
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

    /// The links the run read, across all its link reads; a run whose every
    /// read failed tried to read them.
    private var readAction: String {
        let fetches = steps.flatMap { step -> [URLFetchState] in
            if case .urlFetches(let group) = step { return group }
            return []
        }
        let read = fetches.filter { $0.status == .completed }.count
        if read > 0 { return read == 1 ? "read a link" : "read \(read) links" }
        return fetches.count == 1 ? "tried to read a link" : "tried to read \(fetches.count) links"
    }
}

/// The header of a work row. While the work runs it shows a progress
/// indicator, what the work is doing and how long it has run; once the work
/// settles, what it did. The chevron after the text turns down while the
/// row is open.
struct WorkHeader: View {
    let label: WorkLabel
    let isActive: Bool
    /// When the work started, in epoch milliseconds. Work with no stamp
    /// counts from when its header first showed.
    let startedAt: Double?
    let isExpanded: Bool
    let detailsName: String
    let isDarkMode: Bool
    let onToggle: () -> Void

    @State private var shownAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var start: Date {
        startedAt.map { Date(timeIntervalSince1970: $0 / Constants.UI.WorkSteps.millisecondsPerSecond) } ?? shownAt
    }

    var body: some View {
        if isActive {
            TimelineView(.periodic(from: start, by: Constants.UI.WorkSteps.elapsedTickSeconds)) { context in
                header(elapsed: context.date.timeIntervalSince(start))
            }
        } else {
            header(elapsed: nil)
        }
    }

    private func header(elapsed: TimeInterval?) -> some View {
        Button(action: onToggle) {
            HStack(spacing: Constants.UI.WorkSteps.headerSpacing) {
                if elapsed != nil {
                    InlineLoadingDotsView(isDarkMode: isDarkMode)
                }
                labelText
                if let elapsed {
                    Text(ElapsedTime.label(elapsed))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.45))
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isDarkMode ? .white.opacity(0.4) : .black.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? Constants.UI.WorkSteps.chevronExpandedRotation : 0))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: Constants.UI.WorkSteps.chevronAnimationDuration),
                        value: isExpanded
                    )
                    .fixedSize()
            }
            .padding(.vertical, Constants.UI.WorkSteps.headerVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoHighlightButtonStyle())
        .accessibilityLabel(elapsed.map { "\(label.text), \(ElapsedTime.spokenLabel($0))" } ?? label.text)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the \(detailsName)" : "Shows the \(detailsName)")
    }

    /// Live text stays on one line so the time after it stays in view; what
    /// a settled step did wraps at large text sizes rather than being cut.
    @ViewBuilder
    private var labelText: some View {
        let text = Text(label.text)
            .font(.subheadline)
            .foregroundColor(labelColor)
            .lineLimit(label.tone == .live ? 1 : nil)
            .truncationMode(.tail)
        if label.shimmers {
            text.modifier(TextShimmerAnimation())
        } else {
            text
        }
    }

    private var labelColor: Color {
        switch label.tone {
        case .live: return isDarkMode ? .white : .black.opacity(0.8)
        case .settled: return isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6)
        case .failed: return .red.opacity(0.8)
        case .blocked: return .orange.opacity(0.8)
        }
    }
}

/// A thought, searches or link reads standing alone in a reply: a header
/// that opens the step's details in a box below it.
struct WorkStepBox: View {
    let step: WorkStep
    let rowId: String
    let isActive: Bool
    let isDarkMode: Bool
    let thinkingSummary: String?
    let webSearchSummary: String?
    @ObservedObject var expansion: WorkStepExpansion

    var body: some View {
        let isExpanded = expansion.isExpanded(rowId)
        VStack(alignment: .leading, spacing: 0) {
            WorkHeader(
                label: step.label(isActive: isActive, thinkingSummary: thinkingSummary, webSearchSummary: webSearchSummary),
                isActive: isActive,
                startedAt: step.startedAt,
                isExpanded: isExpanded,
                detailsName: step.detailsName,
                isDarkMode: isDarkMode,
                onToggle: { expansion.toggleLoneStep(step, rowId: rowId) }
            )
            if isExpanded {
                WorkStepDetails(step: step, isDarkMode: isDarkMode)
                    .padding(.horizontal, Constants.UI.WorkSteps.boxPadding)
                    .padding(.top, step.detailsInsets.top)
                    .padding(.bottom, step.detailsInsets.bottom)
                    .workStepsBox(isDarkMode: isDarkMode)
            }
        }
    }
}

/// A run of work in a reply: a header for the whole run that opens a box
/// listing its steps, each of which opens in place to its details.
struct WorkBox: View {
    let run: WorkRun
    let rowId: String
    /// The run is the latest row of a reply that is streaming.
    let isActive: Bool
    let isStreaming: Bool
    let isDarkMode: Bool
    let thinkingSummary: String?
    let webSearchSummary: String?
    @ObservedObject var expansion: WorkStepExpansion

    var body: some View {
        let isExpanded = expansion.isExpanded(rowId)
        VStack(alignment: .leading, spacing: 0) {
            WorkHeader(
                label: run.label(isActive: isActive, thinkingSummary: thinkingSummary, webSearchSummary: webSearchSummary),
                isActive: isActive,
                startedAt: run.startedAt,
                isExpanded: isExpanded,
                detailsName: "steps",
                isDarkMode: isDarkMode,
                onToggle: { expansion.toggle(rowId) }
            )
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Rectangle()
                                .fill(workStepsBorderColor(isDarkMode: isDarkMode))
                                .frame(height: Constants.UI.WorkSteps.boxBorderWidth)
                        }
                        stepRow(step, at: index)
                    }
                }
                .workStepsBox(isDarkMode: isDarkMode)
            }
        }
    }

    /// A step of the run: its own header, live while that step runs, which
    /// opens the step's details below it.
    private func stepRow(_ step: WorkStep, at index: Int) -> some View {
        let stepRowId = WorkRun.stepRowId(step, at: index, in: rowId)
        let isStepActive = isStreaming && step.isInFlight
        let isStepExpanded = expansion.isExpanded(stepRowId)
        return VStack(alignment: .leading, spacing: 0) {
            WorkHeader(
                label: step.label(
                    isActive: isStepActive,
                    thinkingSummary: isStepActive ? thinkingSummary : nil,
                    webSearchSummary: isStepActive ? webSearchSummary : nil
                ),
                isActive: isStepActive,
                startedAt: step.startedAt,
                isExpanded: isStepExpanded,
                detailsName: step.detailsName,
                isDarkMode: isDarkMode,
                onToggle: { expansion.toggle(stepRowId) }
            )
            if isStepExpanded {
                WorkStepDetails(step: step, isDarkMode: isDarkMode)
                    .padding(.bottom, step.detailsInsets.bottom)
            }
        }
        .padding(.horizontal, Constants.UI.WorkSteps.boxPadding)
    }
}

/// What a step holds: a thought's text, each search with its results, or
/// each link read, failed ones included.
private struct WorkStepDetails: View {
    let step: WorkStep
    let isDarkMode: Bool

    var body: some View {
        switch step {
        case .thinking(let content, _, _, _):
            ThoughtText(content: content, isDarkMode: isDarkMode)
        case .webSearches(let group):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group) { instance in
                    WebSearchQueryRow(instance: instance, isDarkMode: isDarkMode)
                }
            }
        case .urlFetches(let group):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group) { fetch in
                    URLFetchRow(fetch: fetch, isDarkMode: isDarkMode)
                }
            }
        }
    }
}

/// A thought's text in chunks, so a very long thought never lays out as
/// one Text whose layout blocks the main thread.
private struct ThoughtText: View {
    let content: String
    let isDarkMode: Bool

    @State private var chunks: [ThinkingChunk]? = nil

    var body: some View {
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
        // A thought still streaming is chunked again as it grows.
        .task(id: content) {
            guard !content.isEmpty else { return }
            let text = content
            let chunked = await Task.detached {
                ThinkingTextChunker.chunk(growing: text)
            }.value
            guard !Task.isCancelled else { return }
            chunks = chunked
        }
    }
}

private extension WorkStep {
    /// The space a box leaves above and below a step's details. Each kind's
    /// rows pad themselves, so the box adds what brings them to its padding.
    var detailsInsets: (top: CGFloat, bottom: CGFloat) {
        let layout = Constants.UI.WorkSteps.self
        switch self {
        case .thinking:
            return (layout.boxPadding, layout.boxPadding - layout.thoughtParagraphSpacing)
        case .webSearches:
            return (layout.boxPadding - layout.searchRowPadding, layout.boxPadding - layout.searchRowPadding)
        case .urlFetches:
            return (layout.boxPadding - layout.linkRowPadding, layout.boxPadding - layout.linkRowPadding)
        }
    }
}

private func workStepsBorderColor(isDarkMode: Bool) -> Color {
    isDarkMode ? .white.opacity(0.1) : .black.opacity(0.1)
}

private extension View {
    /// The bordered box a work row opens its details in.
    func workStepsBox(isDarkMode: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Constants.UI.WorkSteps.boxCornerRadius)
                    .stroke(workStepsBorderColor(isDarkMode: isDarkMode), lineWidth: Constants.UI.WorkSteps.boxBorderWidth)
            )
    }
}
