import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

@Suite("Streaming response completion")
struct StreamingResponseProcessorTests {
    @Test("rejects a response without a finish reason")
    func rejectsIncompleteResponse() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        let parsed = processor.parse(try chunk(content: "partial"))
        _ = processor.process(parsed)

        #expect(throws: StreamingResponseProcessorError.self) {
            try processor.finishStream()
        }
    }

    @Test("accepts authenticated finish reasons", arguments: [
        "stop",
        "length",
        "content_filter",
        "tool_calls",
        "function_call",
    ])
    func acceptsFinishReason(_ finishReason: String) throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        let content = processor.parse(try chunk(content: "complete"))
        _ = processor.process(content)
        let terminal = processor.parse(
            try chunk(content: "", finishReason: finishReason)
        )
        _ = processor.process(terminal)

        try processor.finishStream()

        #expect(processor.snapshot().responseContent == "complete")
    }

    @Test("stores the routed model display name")
    func storesRoutedModelDisplayName() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false,
            modelDisplayName: "Auto · Smart",
            modelDisplayNamesByName: ["gpt-oss-120b": "GPT-OSS 120B"]
        )

        _ = processor.process(processor.parse(try chunk(content: "complete")))

        #expect(processor.snapshot().modelDisplayName == "GPT-OSS 120B")
    }

    @Test("keeps the selected display name when the routed model is unknown")
    func keepsSelectedModelDisplayName() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false,
            modelDisplayName: "Auto · Smart"
        )

        _ = processor.process(processor.parse(try chunk(content: "complete")))

        #expect(processor.snapshot().modelDisplayName == "Auto · Smart")
    }

    private func chunk(
        content: String,
        finishReason: String? = nil
    ) throws -> ChatStreamResult {
        try decodeStreamChunk(delta: ["content": content], finishReason: finishReason)
    }
}

@Suite("Lazy streaming snapshot publication")
struct LazyStreamingSnapshotPublisherTests {
    @Test("fast stream cancels trailing and builds leading and final snapshots")
    func fastStreamCancelsTrailingSnapshot() {
        var latestValue = 0
        var materializationCount = 0
        let publisher = LazySnapshotPublisher(
            interval: Constants.Streaming.uiUpdateInterval
        ) {
            materializationCount += 1
            return latestValue
        }
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        for value in 1...100 {
            latestValue = value
            publisher.markDirty()
            _ = publisher.acceptUpdate(
                at: start.addingTimeInterval(TimeInterval(value - 1) / 10_000),
                scheduleTrailing: true
            )
        }

        publisher.cancelTrailing()
        #expect(publisher.finish().snapshot == 100)
        #expect(materializationCount == 2)
    }

    @Test("trailing publication materializes the latest state")
    func latestStateWinsTrailingPublication() throws {
        var latestValue = "first"
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        var materializationCount = 0
        let countingPublisher = LazySnapshotPublisher(
            interval: Constants.Streaming.uiUpdateInterval
        ) {
            materializationCount += 1
            return latestValue
        }

        countingPublisher.markDirty()
        #expect(countingPublisher.acceptUpdate(
            at: start,
            scheduleTrailing: true
        ).materializedSnapshot?.snapshot == "first")
        latestValue = "intermediate"
        countingPublisher.markDirty()
        let scheduled = countingPublisher.acceptUpdate(
            at: start.addingTimeInterval(0.01),
            scheduleTrailing: true
        )
        latestValue = "latest"
        countingPublisher.markDirty()
        _ = countingPublisher.acceptUpdate(
            at: start.addingTimeInterval(0.02),
            scheduleTrailing: true
        )

        let fireTime = try #require(scheduled.trailingFireTime)
        #expect(countingPublisher.publishTrailing(scheduledFor: fireTime)?.snapshot == "latest")
        #expect(materializationCount == 2)
    }

    @Test("cancellation flushes the latest dirty state once")
    func cancellationFlushesOnce() {
        var latestValue = 1
        var materializationCount = 0
        let publisher = LazySnapshotPublisher(
            interval: Constants.Streaming.uiUpdateInterval
        ) {
            materializationCount += 1
            return latestValue
        }
        let start = Date(timeIntervalSinceReferenceDate: 3_000)

        publisher.markDirty()
        _ = publisher.acceptUpdate(at: start, scheduleTrailing: true)
        latestValue = 2
        publisher.markDirty()
        _ = publisher.acceptUpdate(
            at: start.addingTimeInterval(0.01),
            scheduleTrailing: true
        )

        #expect(publisher.flushIfDirty()?.snapshot == 2)
        #expect(publisher.flushIfDirty() == nil)
        #expect(materializationCount == 2)
    }

    @Test("recovery throttle skips intermediate builds and finishes exactly")
    func recoveryThrottleSkipsIntermediateBuilds() {
        var content = ""
        var materializationCount = 0
        let publisher = LazySnapshotPublisher(
            interval: Constants.Streaming.uiUpdateInterval
        ) {
            materializationCount += 1
            return content
        }
        let start = Date(timeIntervalSinceReferenceDate: 4_000)

        let interval = Constants.Streaming.uiUpdateInterval
        let updateTimes: [TimeInterval] = [
            0,
            interval / 2,
            interval,
            interval * 1.5,
            interval * 2,
        ]
        for updateTime in updateTimes {
            content += "x"
            publisher.markDirty()
            _ = publisher.acceptUpdate(
                at: start.addingTimeInterval(updateTime),
                scheduleTrailing: false
            )
        }

        let finalContent = publisher.finish().snapshot
        #expect(finalContent == String(repeating: "x", count: updateTimes.count))
        #expect(materializationCount == 4)
    }

    @Test("publication fence rejects an older delayed snapshot")
    func publicationFenceRejectsOlderSnapshot() throws {
        var latestValue = 1
        let publisher = LazySnapshotPublisher(
            interval: Constants.Streaming.uiUpdateInterval
        ) { latestValue }
        let fence = SnapshotPublicationFence()
        let start = Date(timeIntervalSinceReferenceDate: 5_000)

        publisher.markDirty()
        _ = publisher.acceptUpdate(at: start, scheduleTrailing: true)
        latestValue = 2
        publisher.markDirty()
        let scheduled = publisher.acceptUpdate(
            at: start.addingTimeInterval(0.01),
            scheduleTrailing: true
        )
        let fireTime = try #require(scheduled.trailingFireTime)
        let older = try #require(publisher.publishTrailing(scheduledFor: fireTime))
        latestValue = 3
        publisher.markDirty()
        let newer = try #require(publisher.acceptUpdate(
            at: start.addingTimeInterval(0.2),
            scheduleTrailing: true
        ).materializedSnapshot)

        #expect(newer.id > older.id)
        #expect(fence.accept(newer.id))
        #expect(!fence.accept(older.id))
    }
}

@Suite("Streaming thinking segments")
struct StreamingThinkingSegmentTests {

    @Test("reasoning then content closes the thinking segment in order")
    func reasoningThenContent() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        _ = processor.process(processor.parse(try reasoningChunk("Let me think.")))
        _ = processor.process(processor.parse(try contentChunk("Answer.")))

        let snapshot = processor.snapshot()
        #expect(snapshot.isThinking == false)
        #expect(snapshot.segments.count == 2)
        guard case .thinking(let thought, let isThinking, let duration) = snapshot.segments[0] else {
            Issue.record("Expected a thinking segment first, got \(snapshot.segments)")
            return
        }
        #expect(thought == "Let me think.")
        #expect(isThinking == false)
        #expect(duration != nil)
        #expect(snapshot.segments[1] == .text("Answer."))
    }

    @Test("reasoning_content is decoded into thinking state")
    func reasoningContentIsDecoded() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        let chunk = try decodeStreamChunk(delta: ["reasoning_content": "K3 thought."])
        _ = processor.process(processor.parse(chunk))

        #expect(processor.snapshot().thoughts == "K3 thought.")
    }

    @Test("web search closes the open thinking round")
    func webSearchClosesThinking() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: true,
            hapticEnabled: false
        )
        _ = processor.process(processor.parse(try reasoningChunk("Need to search.")))

        var snapshot = processor.snapshot()
        #expect(snapshot.isThinking == true)

        // A web search event arrives mid-thinking (applied on the main
        // actor between chunks, as the view model does).
        processor.markWebSearchStarted()
        processor.upsertWebSearch(
            WebSearchInstance(id: "ws-0", query: "q", status: .searching, sources: nil, reason: nil)
        )

        snapshot = processor.snapshot()
        #expect(snapshot.isThinking == false)
        #expect(snapshot.segments.count == 2)
        guard case .thinking(_, let isThinking, let duration) = snapshot.segments[0] else {
            Issue.record("Expected a thinking segment first, got \(snapshot.segments)")
            return
        }
        #expect(isThinking == false)
        #expect(duration != nil)
        #expect(snapshot.segments[1] == .webSearch(searchId: "ws-0"))
    }

    @Test("reasoning after a tool boundary opens a new thinking segment")
    func newThinkingRoundAfterToolBoundary() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: true,
            hapticEnabled: false
        )
        _ = processor.process(processor.parse(try reasoningChunk("First round.")))
        processor.upsertWebSearch(
            WebSearchInstance(id: "ws-0", query: "q", status: .searching, sources: nil, reason: nil)
        )
        _ = processor.process(processor.parse(try reasoningChunk("Second round.")))
        _ = processor.process(processor.parse(try contentChunk("Answer.")))

        let snapshot = processor.snapshot()
        #expect(snapshot.segments.count == 4)
        guard case .thinking(let first, false, .some) = snapshot.segments[0],
              case .webSearch(let searchId) = snapshot.segments[1],
              case .thinking(let second, false, .some) = snapshot.segments[2],
              case .text(let text) = snapshot.segments[3] else {
            Issue.record("Unexpected segment shape: \(snapshot.segments)")
            return
        }
        #expect(first == "First round.")
        #expect(searchId == "ws-0")
        #expect(second == "Second round.")
        #expect(text == "Answer.")
        #expect(snapshot.thoughts == "First round.\n\nSecond round.")
        var message = Message(role: .assistant, content: snapshot.responseContent, thoughts: snapshot.thoughts)
        message.segments = snapshot.segments
        #expect(message.reasoningContentForHistory == "First round.Second round.")
    }

    @Test("tool call deltas close the open thinking round")
    func toolCallClosesThinking() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        _ = processor.process(processor.parse(try reasoningChunk("Considering a widget.")))
        _ = processor.process(processor.parse(try toolCallChunk(id: "call_1", name: "widget", arguments: "{}")))

        let snapshot = processor.snapshot()
        #expect(snapshot.isThinking == false)
        #expect(snapshot.segments.count == 2)
        guard case .thinking(_, false, .some) = snapshot.segments[0] else {
            Issue.record("Expected a closed thinking segment first, got \(snapshot.segments)")
            return
        }
        #expect(snapshot.segments[1] == .toolCall(toolCallId: "call_1"))
    }

    @Test("stream end closes an open thinking round")
    func streamEndClosesThinking() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        _ = processor.process(processor.parse(try reasoningChunk("Unfinished thought.")))
        _ = processor.process(processor.parse(try contentChunk("", finishReason: "stop")))

        try processor.finishStream()

        let snapshot = processor.snapshot()
        #expect(snapshot.isThinking == false)
        #expect(snapshot.segments.count == 1)
        guard case .thinking(let thought, false, .some) = snapshot.segments[0] else {
            Issue.record("Expected a closed thinking segment, got \(snapshot.segments)")
            return
        }
        #expect(thought == "Unfinished thought.")
    }

    @Test("late reasoning tail merges into the closed thinking segment")
    func lateReasoningTailMerges() throws {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: false,
            hapticEnabled: false
        )
        _ = processor.process(processor.parse(try reasoningChunk("Thought start")))
        _ = processor.process(processor.parse(try contentChunk("Answer.")))
        _ = processor.process(processor.parse(try reasoningChunk(" and tail.")))

        let snapshot = processor.snapshot()
        #expect(snapshot.segments.count == 2)
        guard case .thinking(let thought, false, _) = snapshot.segments[0] else {
            Issue.record("Expected a thinking segment first, got \(snapshot.segments)")
            return
        }
        #expect(thought == "Thought start and tail.")
        #expect(snapshot.segments[1] == .text("Answer."))
    }

    private func reasoningChunk(_ reasoning: String) throws -> ChatStreamResult {
        try decodeStreamChunk(delta: ["reasoning": reasoning])
    }

    private func contentChunk(
        _ content: String,
        finishReason: String? = nil
    ) throws -> ChatStreamResult {
        try decodeStreamChunk(delta: ["content": content], finishReason: finishReason)
    }

    private func toolCallChunk(
        id: String,
        name: String,
        arguments: String
    ) throws -> ChatStreamResult {
        try decodeStreamChunk(delta: [
            "tool_calls": [
                [
                    "index": 0,
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": arguments],
                ]
            ]
        ])
    }
}

/// Builds and decodes a `ChatStreamResult` fixture from a raw delta payload.
private func decodeStreamChunk(
    delta: [String: Any],
    finishReason: String? = nil
) throws -> ChatStreamResult {
    var choice: [String: Any] = [
        "index": 0,
        "delta": delta,
    ]
    choice["finish_reason"] = finishReason.map { $0 as Any } ?? NSNull()
    let data = try JSONSerialization.data(withJSONObject: [
        "id": "chatcmpl-test",
        "object": "chat.completion.chunk",
        "created": 1,
        "model": "gpt-oss-120b",
        "choices": [choice],
    ])
    return try JSONDecoder().decode(ChatStreamResult.self, from: data)
}
