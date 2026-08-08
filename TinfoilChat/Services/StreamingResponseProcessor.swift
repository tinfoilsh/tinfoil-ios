//
//  StreamingResponseProcessor.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.

import Foundation
import OpenAI

enum StreamingResponseProcessorError: Error {
    case incompleteResponse
}

/// Owns all per-chunk parsing state for one streaming response (event
/// markers, thinking state machine, chunkers, tool calls, web search
/// bookkeeping) so the stream can be consumed off the main actor. The main
/// actor only receives immutable snapshots and per-chunk outcomes.
///
/// Thread-safety contract (`@unchecked Sendable`): the stream task is the
/// single consumer. The main actor touches the processor only through the
/// event-application accessors, and only while the stream task is suspended
/// awaiting that main-actor hop, so all access is serialized even though the
/// class is not internally synchronized.
final class StreamingResponseProcessor: @unchecked Sendable {

    /// Everything the UI writes onto the streaming message. Captured as a
    /// value so the main actor never reads live processor state.
    struct Snapshot {
        var responseContent: String
        var modelDisplayName: String?
        var thoughts: String?
        var thinkingChunks: [ThinkingChunk]
        var contentChunks: [ContentChunk]
        var isThinking: Bool
        var generationTimeSeconds: TimeInterval?
        var segments: [MessageSegment]
        var webSearches: [WebSearchInstance]
        var toolCalls: [GenUIToolCall]
        var timelineBlocks: [JSONValue]
        var collectedSources: [WebSearchSource]
        var collectedAnnotations: [Annotation]
        var webSearchBeforeThinking: Bool?
    }

    /// Main-actor side effects produced while processing one chunk.
    struct ChunkOutcome {
        var didMutateState = false
        var shouldTickHaptic = false
        var summaryActions: [SummaryAction] = []
    }

    enum SummaryAction {
        case beginThinkingSession
        case endThinkingSession
        case generate(String)
    }

    /// One chunk with its `<tinfoil-event>` markers stripped and decoded.
    struct ParsedChunk {
        let chunk: ChatStreamResult
        let content: String
        let events: [TinfoilWebSearchCallEvent]
    }

    // Stateful parser for `<tinfoil-event>` markers embedded
    // in the content stream. When the router isn't asked to
    // emit markers it sends none, so the parser is a pure
    // pass-through.
    private var tinfoilEventParser = TinfoilEventParser()
    private let chunker = StreamingMarkdownChunker()
    private let thinkingChunker = ThinkingTextChunker()

    // Ordered content segments (text + inline event refs) that preserve
    // the exact order in which events arrived relative to streamed text.
    private var segments: [MessageSegment] = []
    // Index of the currently-open `.thinking` segment, if a thinking
    // round is in flight. Each thinking round (agentic models think
    // again between tool calls) gets its own ordered segment so the UI
    // interleaves thought boxes with tool calls chronologically.
    private var currentThinkingSegmentIndex: Int? = nil
    // Total thinking time accumulated across all rounds; feeds the
    // flat `generationTimeSeconds` while each segment keeps its own
    // per-round duration.
    private var totalThinkingSeconds: TimeInterval = 0
    private var webSearches: [WebSearchInstance] = []
    private var nextSearchId = 0
    // Track whether web search started before thinking (shared across the
    // event application and the streaming state machine).
    private var webSearchStarted = false

    // GenUI tool-call accumulator. The OpenAI streaming
    // protocol sends a sequence of partial deltas keyed by
    // `index`; each delta may carry an `id`, a `name`, and
    // an `arguments` fragment. We coalesce them by index
    // and write both:
    //   - the flat `Message.toolCalls` array (mirrored from
    //     webapp `MessageAssembler.toMessage`), and
    //   - the canonical `Message.timeline` tool_call blocks
    //     that the webapp uses to track resolution state.
    private var streamingToolCalls: [Int: GenUIToolCall] = [:]
    private var timelineBlocks: [JSONValue] = []

    // Summary actions produced outside `process` (thinking rounds closed
    // by tool boundaries during main-actor event application). Drained
    // into the next chunk outcome so the summary session state stays in
    // sync without an extra main-actor channel.
    private var pendingSummaryActions: [SummaryAction] = []

    // Web search state tracking
    private var collectedSources: [WebSearchSource] = []
    private var collectedAnnotations: [Annotation] = []

    private var thinkStartTime: Date? = nil
    private var thoughtsBuffer = ""
    private var isInThinkingMode: Bool
    private var isUsingReasoningFormat = false
    // True while thinking was closed by answer content (not by
    // a tool boundary). Reasoning arriving in that state is the
    // late tail of the previous thought — upstreams race the
    // think-close boundary so the final reasoning fragment can
    // land after content started — and is merged into the
    // existing thoughts without re-entering thinking mode.
    private var thinkingClosedByContent = false
    private var didRecordWebSearchBeforeThinking = false
    private var webSearchBeforeThinking: Bool? = nil
    private var responseContent: String
    private var modelDisplayName: String?
    private let modelDisplayNamesByName: [String: String]
    private var currentThoughts: String?
    private var generationTimeSeconds: TimeInterval?
    private var receivedFinishReason = false

    private let isWebSearchEnabled: Bool
    private let hapticEnabled: Bool
    private var hapticChunkCount = 0
    private var lastHapticTime = Date.distantPast
    private let minHapticInterval: TimeInterval = 0.1
    private var hasStartedResponse = false

    init(
        isWebSearchEnabled: Bool,
        hapticEnabled: Bool,
        responseContent: String = "",
        modelDisplayName: String? = nil,
        modelDisplayNamesByName: [String: String] = [:],
        currentThoughts: String? = nil,
        generationTimeSeconds: TimeInterval? = nil,
        isInThinkingMode: Bool = false
    ) {
        self.isWebSearchEnabled = isWebSearchEnabled
        self.hapticEnabled = hapticEnabled
        self.responseContent = responseContent
        self.modelDisplayName = modelDisplayName
        self.modelDisplayNamesByName = modelDisplayNamesByName
        self.currentThoughts = currentThoughts
        self.generationTimeSeconds = generationTimeSeconds
        self.isInThinkingMode = isInThinkingMode
        self.totalThinkingSeconds = generationTimeSeconds ?? 0
    }

    // MARK: - Event application accessors (main actor, serialized)

    var currentSegments: [MessageSegment] { segments }
    var currentWebSearches: [WebSearchInstance] { webSearches }
    var currentIsThinking: Bool { isInThinkingMode }
    var currentGenerationTimeSeconds: TimeInterval? { generationTimeSeconds }

    func markWebSearchStarted() {
        webSearchStarted = true
    }

    func allocateSearchId() -> String {
        defer { nextSearchId += 1 }
        return "ws-\(nextSearchId)"
    }

    func appendURLFetchSegment(_ fetchId: String) {
        closeThinkingRoundForToolBoundary()
        segments.append(.urlFetch(fetchId: fetchId))
    }

    func upsertWebSearch(_ instance: WebSearchInstance) {
        if let idx = webSearches.firstIndex(where: { $0.id == instance.id }) {
            webSearches[idx] = instance
        } else {
            closeThinkingRoundForToolBoundary()
            webSearches.append(instance)
            segments.append(.webSearch(searchId: instance.id))
        }
    }

    func findSearchInstance(matching eventId: String?) -> WebSearchInstance? {
        if let eventId = eventId,
           let hit = webSearches.first(where: { $0.id == eventId }) {
            return hit
        }
        return webSearches.last
    }

    // MARK: - Chunk processing (stream task)

    /// Strip router-emitted `<tinfoil-event>` markers from the delta before
    /// any downstream logic sees it. The decoded events must be applied on
    /// the main actor before `process` runs so segment ordering matches the
    /// order in which markers arrived relative to the surrounding text.
    func parse(_ chunk: ChatStreamResult) -> ParsedChunk {
        if chunk.choices.contains(where: { $0.finishReason != nil }) {
            receivedFinishReason = true
        }
        var content = chunk.choices.first?.delta.content ?? ""
        var events: [TinfoilWebSearchCallEvent] = []
        if !content.isEmpty {
            let parsed = tinfoilEventParser.consume(content)
            events = parsed.events
            if !parsed.events.isEmpty {
                thinkingClosedByContent = false
            }
            content = parsed.text
        }
        return ParsedChunk(chunk: chunk, content: content, events: events)
    }

    func process(_ parsed: ParsedChunk) -> ChunkOutcome {
        var outcome = ChunkOutcome()
        outcome.shouldTickHaptic = evaluateHapticTick()

        let chunk = parsed.chunk
        let content = parsed.content
        if let resolvedModelDisplayName = modelDisplayNamesByName[chunk.model],
           resolvedModelDisplayName != modelDisplayName {
            modelDisplayName = resolvedModelDisplayName
            outcome.didMutateState = true
        }
        let hasReasoningContent = chunk.choices.first?.delta.reasoning != nil
        let reasoningContent = chunk.choices.first?.delta.reasoning ?? ""

        // Thinking rounds closed by tool boundaries during main-actor
        // event application queue their summary teardown here; forward
        // it with this chunk's outcome.
        if !pendingSummaryActions.isEmpty {
            outcome.summaryActions.append(contentsOf: pendingSummaryActions)
            pendingSummaryActions.removeAll()
            outcome.didMutateState = true
        }

        // Accumulate GenUI tool-call deltas. Mirrors the
        // webapp's normalizer: deltas may carry only
        // partial fragments and we merge them by index.
        // Each merged tool call is also reflected on the
        // canonical `timeline` so the wire format matches
        // `TimelineToolCallBlock` exactly.
        if let deltas = chunk.choices.first?.delta.toolCalls {
            thinkingClosedByContent = false
            closeThinkingRoundForToolBoundary()
            if !pendingSummaryActions.isEmpty {
                outcome.summaryActions.append(contentsOf: pendingSummaryActions)
                pendingSummaryActions.removeAll()
            }
            for delta in deltas {
                let index = delta.index
                let existing = streamingToolCalls[index]
                let mergedId = delta.id ?? existing?.id ?? ""
                let mergedName = delta.function?.name ?? existing?.name ?? ""
                let mergedArgs = (existing?.arguments ?? "") + (delta.function?.arguments ?? "")
                let updated = GenUIToolCall(
                    id: mergedId,
                    name: mergedName,
                    arguments: mergedArgs
                )
                streamingToolCalls[index] = updated
                if !mergedId.isEmpty {
                    appendToolCallSegment(mergedId)
                    TimelineToolCalls.upsertStreamingBlock(
                        in: &timelineBlocks,
                        toolCallId: mergedId,
                        name: mergedName,
                        arguments: mergedArgs
                    )
                }
                outcome.didMutateState = true
            }
        }

        // Collect sources from annotations (no deduplication to preserve citation index mapping)
        if isWebSearchEnabled, let annotations = chunk.choices.first?.delta.annotations {
            var didCollectNewSource = false
            for annotation in annotations where annotation.type == "url_citation" {
                let citation = annotation.urlCitation
                let source = WebSearchSource(
                    title: citation.title,
                    url: citation.url
                )
                collectedSources.append(source)
                collectedAnnotations.append(
                    Annotation(
                        type: "url_citation",
                        url_citation: URLCitation(
                            title: citation.title,
                            url: citation.url,
                            start_index: nil,
                            end_index: nil
                        )
                    )
                )
                didCollectNewSource = true
                outcome.didMutateState = true
            }
            // Mirror the running sources onto the most recent WebSearchInstance.
            // When the router sent `.completed` before any sources, we held the
            // instance at `.searching` to avoid a zero-source completed pill;
            // promote it now that a source has arrived.
            if didCollectNewSource, let idx = webSearches.indices.last {
                let lastSearch = webSearches[idx]
                let promotedStatus: WebSearchStatus = lastSearch.status == .searching
                    ? .completed
                    : lastSearch.status
                webSearches[idx] = WebSearchInstance(
                    id: lastSearch.id,
                    query: lastSearch.query,
                    status: promotedStatus,
                    sources: collectedSources,
                    reason: lastSearch.reason
                )
            }
        }

        if hasReasoningContent && !isUsingReasoningFormat && !isInThinkingMode {
            isUsingReasoningFormat = true
            isInThinkingMode = true
            thinkingClosedByContent = false
            thinkStartTime = Date()
            if !didRecordWebSearchBeforeThinking {
                didRecordWebSearchBeforeThinking = true
                webSearchBeforeThinking = webSearchStarted
            }
            thoughtsBuffer = reasoningContent
            thinkingChunker.appendToken(reasoningContent)
            currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
            openThinkingSegment(initialContent: reasoningContent)
            outcome.didMutateState = true
            // Reset summary service for new thinking session
            outcome.summaryActions.append(.beginThinkingSession)
            // Some routers attach content to the same chunk as
            // the first reasoning delta; close the thinking
            // session and emit it so the text isn't dropped.
            if !content.isEmpty {
                let roundSeconds = closeThinkingRound()
                isInThinkingMode = false
                thinkingClosedByContent = true
                thinkingChunker.finalize()
                closeThinkingSegment(duration: roundSeconds)
                if responseContent.isEmpty {
                    responseContent = content
                } else {
                    responseContent += content
                }
                chunker.appendToken(content)
                appendText(content)
            }
        } else if isUsingReasoningFormat {
            if !reasoningContent.isEmpty {
                if isInThinkingMode {
                    thoughtsBuffer += reasoningContent
                    thinkingChunker.appendToken(reasoningContent)
                    currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                    updateOpenThinkingSegment(appending: reasoningContent)
                    outcome.didMutateState = true
                    // Generate thinking summary (reuse existing client)
                    outcome.summaryActions.append(.generate(thoughtsBuffer))
                } else if thinkingClosedByContent {
                    // Late tail of the thought that content
                    // already closed. Merge it into the existing
                    // thoughts without re-entering thinking mode,
                    // so the answer isn't split around a phantom
                    // thought.
                    thoughtsBuffer += reasoningContent
                    thinkingChunker.appendTail(reasoningContent)
                    currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                    appendThinkingSegmentTail(reasoningContent)
                    outcome.didMutateState = true
                } else {
                    // Reasoning resumed after a tool boundary —
                    // a new thinking phase of the next model turn
                    // rendered as its own thought box, timed on
                    // its own clock.
                    isInThinkingMode = true
                    thinkStartTime = Date()
                    if !thoughtsBuffer.isEmpty {
                        thoughtsBuffer += "\n\n"
                    }
                    thoughtsBuffer += reasoningContent
                    thinkingChunker.appendToken(reasoningContent)
                    currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                    openThinkingSegment(initialContent: reasoningContent)
                    outcome.didMutateState = true
                    outcome.summaryActions.append(.beginThinkingSession)
                    outcome.summaryActions.append(.generate(thoughtsBuffer))
                }
            }

            if !content.isEmpty && isInThinkingMode {
                let roundSeconds = closeThinkingRound()
                isInThinkingMode = false
                thinkingClosedByContent = true
                thinkingChunker.finalize()
                closeThinkingSegment(duration: roundSeconds)
                currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                // Clear thinking summary and cancel any in-flight summary generation
                outcome.summaryActions.append(.endThinkingSession)
                // Inline appendToResponse
                if responseContent.isEmpty {
                    responseContent = content
                } else {
                    responseContent += content
                }
                chunker.appendToken(content)
                appendText(content)
                outcome.didMutateState = true
            } else if !content.isEmpty {
                if responseContent.isEmpty {
                    responseContent = content
                } else {
                    responseContent += content
                }
                chunker.appendToken(content)
                appendText(content)
                isInThinkingMode = false
                outcome.didMutateState = true
            }
        } else if !isUsingReasoningFormat && !content.isEmpty {
            if responseContent.isEmpty {
                responseContent = content
            } else {
                responseContent += content
            }
            chunker.appendToken(content)
            appendText(content)
            outcome.didMutateState = true
        }

        return outcome
    }

    /// Runs once after a completed stream ends: validates application-level
    /// completion, drains parser tails, closes any open thinking state, and
    /// finalizes the chunkers so `snapshot()` reflects the completed response.
    func finishStream() throws {
        guard receivedFinishReason else {
            throw StreamingResponseProcessorError.incompleteResponse
        }
        // Drain any bytes the tinfoil-event parser is still
        // holding back at the stream boundary. Anything in the
        // tail is either an unterminated marker body (router
        // bug) or a trailing open-tag prefix; surface it as
        // plain assistant content minus any stray tag bytes so
        // no characters the model emitted are silently lost.
        let tinfoilEventTail = tinfoilEventParser.flush()
        if !tinfoilEventTail.isEmpty {
            let sanitizedTail = tinfoilEventTail
                .replacingOccurrences(of: "<tinfoil-event>", with: "")
                .replacingOccurrences(of: "</tinfoil-event>", with: "")
            if !sanitizedTail.isEmpty {
                if responseContent.isEmpty {
                    responseContent = sanitizedTail
                } else {
                    responseContent += sanitizedTail
                }
                _ = chunker.appendToken(sanitizedTail)
                appendText(sanitizedTail)
            }
        }

        // Close any thinking round still open when the stream ends.
        if isInThinkingMode {
            if !thoughtsBuffer.isEmpty {
                currentThoughts = thoughtsBuffer
            }
            let roundSeconds = closeThinkingRound()
            closeThinkingSegment(duration: roundSeconds)
            isInThinkingMode = false
        }

        chunker.finalize()
        thinkingChunker.finalize()

        // Mirror the final sources onto the most recent WebSearchInstance,
        // promoting it out of the `.searching` holding state if the router
        // sent `.completed` before any sources landed.
        if !collectedSources.isEmpty,
           let idx = webSearches.indices.last {
            let lastSearch = webSearches[idx]
            let finalStatus: WebSearchStatus = lastSearch.status == .searching
                ? .completed
                : lastSearch.status
            webSearches[idx] = WebSearchInstance(
                id: lastSearch.id,
                query: lastSearch.query,
                status: finalStatus,
                sources: collectedSources,
                reason: lastSearch.reason
            )
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            responseContent: responseContent,
            modelDisplayName: modelDisplayName,
            thoughts: currentThoughts,
            thinkingChunks: thinkingChunker.getAllChunks(),
            contentChunks: chunker.getAllChunks(),
            isThinking: isInThinkingMode,
            generationTimeSeconds: generationTimeSeconds,
            segments: segments,
            webSearches: webSearches,
            toolCalls: streamingToolCalls
                .sorted(by: { $0.key < $1.key })
                .map { $0.value }
                .filter { !$0.id.isEmpty },
            timelineBlocks: timelineBlocks,
            collectedSources: collectedSources,
            collectedAnnotations: collectedAnnotations,
            webSearchBeforeThinking: webSearchBeforeThinking
        )
    }

    // MARK: - Private helpers

    /// Stops the current thinking round's clock and folds its elapsed time
    /// into the cumulative `generationTimeSeconds`. Returns the round's own
    /// duration for the segment being closed.
    private func closeThinkingRound() -> TimeInterval? {
        guard let startTime = thinkStartTime else { return nil }
        let roundSeconds = Date().timeIntervalSince(startTime)
        thinkStartTime = nil
        totalThinkingSeconds += roundSeconds
        generationTimeSeconds = totalThinkingSeconds
        return roundSeconds
    }

    /// Opens a new ordered `.thinking` segment for a thinking round.
    private func openThinkingSegment(initialContent: String) {
        segments.append(.thinking(content: initialContent, isThinking: true, duration: nil))
        currentThinkingSegmentIndex = segments.count - 1
    }

    private func updateOpenThinkingSegment(appending reasoning: String) {
        guard let idx = currentThinkingSegmentIndex,
              case .thinking(let existing, _, _) = segments[idx] else { return }
        segments[idx] = .thinking(content: existing + reasoning, isThinking: true, duration: nil)
    }

    private func closeThinkingSegment(duration: TimeInterval?) {
        guard let idx = currentThinkingSegmentIndex,
              case .thinking(let existing, _, _) = segments[idx] else {
            currentThinkingSegmentIndex = nil
            return
        }
        segments[idx] = .thinking(content: existing, isThinking: false, duration: duration)
        currentThinkingSegmentIndex = nil
    }

    /// Merges a late reasoning tail into the most recent closed thinking
    /// segment so it doesn't open a phantom thought box.
    private func appendThinkingSegmentTail(_ reasoning: String) {
        for idx in segments.indices.reversed() {
            if case .thinking(let existing, let isThinking, let duration) = segments[idx] {
                segments[idx] = .thinking(
                    content: existing + reasoning,
                    isThinking: isThinking,
                    duration: duration
                )
                return
            }
        }
    }

    /// Closes the in-flight thinking round when a tool call begins so the
    /// thought box freezes to "Thought for Xs" instead of pulsing through
    /// the tool activity. Reasoning arriving afterwards opens a new round.
    private func closeThinkingRoundForToolBoundary() {
        guard isInThinkingMode else { return }
        let roundSeconds = closeThinkingRound()
        isInThinkingMode = false
        thinkingClosedByContent = false
        thinkingChunker.finalize()
        currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
        closeThinkingSegment(duration: roundSeconds)
        pendingSummaryActions.append(.endThinkingSession)
    }

    private func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = segments.last {
            segments[segments.count - 1] = .text(existing + text)
        } else {
            segments.append(.text(text))
        }
    }

    private func appendToolCallSegment(_ toolCallId: String) {
        if !segments.contains(where: {
            if case .toolCall(let id) = $0, id == toolCallId { return true }
            return false
        }) {
            segments.append(.toolCall(toolCallId: toolCallId))
        }
    }

    private func evaluateHapticTick() -> Bool {
        guard hapticEnabled else { return false }
        if !isInThinkingMode && !hasStartedResponse {
            hasStartedResponse = true
            hapticChunkCount = 0
        }
        guard hapticChunkCount < 5 else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastHapticTime) >= minHapticInterval else { return false }
        lastHapticTime = now
        hapticChunkCount += 1
        return true
    }
}
