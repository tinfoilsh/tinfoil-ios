import Foundation
import OpenAPIRuntime
import Testing
@testable import TinfoilChat

@Suite("Chat reducer")
struct ChatReducerTests {
    private static let thread: [String: Any] = [
        "id": "t", "title": "New Chat", "titleState": "placeholder", "createdAt": NSNull(), "updatedAt": NSNull(),
        "activityAt": "2026-01-01T00:00:00Z", "projectId": NSNull(), "model": "auto", "webSearchEnabled": false,
        "pinned": false, "contextUsage": NSNull(), "activeRun": NSNull(), "messageCount": 1,
    ]
    private static let quota: [String: Any] = ["kind": NSNull()]

    private static func frames(_ events: [[String: Any]], from first: Int = 0) throws -> [Frame] {
        try events.enumerated().map { try HarnessProtocolFixtures.frame($0.element, id: first + $0.offset) }
    }

    private static func reduce(_ events: [[String: Any]], from first: Int = 0, into state: ChatState = ChatState()) throws -> ChatState {
        try frames(events, from: first).reduce(state) { try ChatReducer.reduce($0, $1) }
    }

    private static func started(_ runId: String = "r", messageId: String? = nil) -> [String: Any] {
        var event: [String: Any] = ["type": "RUN_STARTED", "threadId": "t", "runId": runId, "instance": "i"]
        if let messageId { event["messageId"] = messageId }
        return event
    }

    private static func snapshot(queue: [[String: Any]] = []) -> [String: Any] {
        ["type": "STATE_SNAPSHOT", "snapshot": ["thread": thread, "queue": queue, "rateLimit": quota]]
    }

    private static func text(_ delta: String, message: String = "m") -> [String: Any] {
        ["type": "TEXT_MESSAGE_CHUNK", "messageId": message, "role": "assistant", "delta": delta]
    }

    private static func reasoning(_ delta: String, message: String = "m") -> [String: Any] {
        ["type": "REASONING_MESSAGE_CHUNK", "messageId": "\(message)-reasoning", "delta": delta]
    }

    private static func finished(_ runId: String = "r") -> [String: Any] {
        ["type": "RUN_FINISHED", "threadId": "t", "runId": runId, "metadata": [:]]
    }

    private static func queued(_ id: String) -> [String: Any] {
        ["queueId": id, "kind": "send", "content": "later", "quote": NSNull(), "attachments": [], "createdAt": "2026-01-01T00:00:00Z"]
    }

    private static func blocks(_ state: ChatState, of message: String = "m") -> [TimelineBlock] {
        state.messages.first { $0.id == message }?.timeline ?? []
    }

    @Test func aFrameAppliedAlreadyChangesNothing() throws {
        let state = try Self.reduce([Self.started(), Self.snapshot(), Self.text("one")])
        let replayed = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(Self.text("one"), id: 2))
        #expect(replayed == state)
        let later = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(Self.text(" two"), id: 3))
        #expect(Self.blocks(later).first?.content == "one two")
        #expect(later.cursors["r"] == 3)
    }

    @Test func aTitleStatePatchChangesTheTitleStateAndNotTheTitle() throws {
        let state = try Self.reduce([
            Self.started(), Self.snapshot(),
            ["type": "STATE_DELTA", "delta": [
                ["op": "replace", "path": "/thread/title", "value": "Cats"],
                ["op": "replace", "path": "/thread/titleState", "value": "generated"],
            ]],
        ])
        #expect(state.snapshot.thread?.title == "Cats")
        #expect(state.snapshot.thread?.titleState.value1 == .generated)
    }

    @Test func aTitleStateThisClientDoesNotKnowIsKept() throws {
        let state = try Self.reduce([
            Self.started(), Self.snapshot(),
            ["type": "STATE_DELTA", "delta": [["op": "replace", "path": "/thread/titleState", "value": "translated"]]],
        ])
        #expect(state.snapshot.thread?.titleState == Components.Schemas.TitleState(raw: "translated"))
        #expect(state.snapshot.thread?.titleState.value1 == nil)
    }

    @Test func aMessageOfARoleThisClientDoesNotKnowIsLeftOut() throws {
        let messages: [[String: Any]] = [
            ["id": "u", "role": "user", "createdAt": "", "content": "hi"],
            ["id": "n", "role": "narrator", "createdAt": "", "content": "meanwhile"],
            ["id": "a", "role": "assistant", "createdAt": "", "timeline": []],
        ]
        let streamed = try Self.reduce([Self.started(), ["type": "MESSAGES_SNAPSHOT", "messages": messages, "hasOlder": false]])
        #expect(streamed.messages.map(\.id) == ["u", "a"])
        var window = Self.thread
        window.merge(["revision": "1", "presetId": NSNull(), "messages": messages, "hasOlder": false]) { $1 }
        let loaded = ChatState(thread: try ThreadWindow(jsonObject: window))
        #expect(loaded.messages.map(\.id) == ["u", "a"])
    }

    @Test func aCutOffRunKeepsWhatItStreamedIntoAContinuedReplyUntilItsThreadIsStored() throws {
        let question: [String: Any] = ["id": "q", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "Go on"]
        let half: [String: Any] = ["id": "m", "role": "assistant", "createdAt": "2026-01-01T00:00:01Z", "timeline": [["id": "m_content_0", "type": "content", "content": "Half"]]]
        let state = try Self.reduce([
            Self.started(messageId: "m"),
            ["type": "MESSAGES_SNAPSHOT", "messages": [question, half], "hasOlder": false],
            Self.text(", then more"),
        ])

        // The stored copy holds the reply as it was before the run went on.
        let kept = ChatReducer.cutOffReplies(state, storedIds: ["q", "m"], unstored: true)
        #expect(kept.map(\.id) == ["m"])
        #expect(kept.first?.timeline?.first?.content == "Half, then more")
        #expect(kept.first?.isInterrupted == true)
        // A copy the run's final event replaced holds all the run streamed.
        #expect(ChatReducer.cutOffReplies(state, storedIds: ["q", "m"], unstored: false).isEmpty)
    }

    @Test func aCutOffReplyTakesItsPlaceBeforeTheMessagesSentAfterIt() {
        let question = HarnessMessage(id: "q", role: .named(.user), createdAt: "")
        let reply = HarnessMessage(id: "m", role: .named(.assistant), createdAt: "", isInterrupted: true)
        let later = HarnessMessage(id: "q2", role: .named(.user), createdAt: "")

        let merged = ChatReducer.withReplies([question, later], [reply], shown: [question, reply]) { $0.id }

        #expect(merged.map(\.id) == ["q", "m", "q2"])
    }

    @Test func aPatchTheProtocolDoesNotNameFailsTheStream() throws {
        let state = try Self.reduce([Self.started(), Self.snapshot()])
        let patch = try HarnessProtocolFixtures.frame(
            ["type": "STATE_DELTA", "delta": [["op": "remove", "path": "/thread/title", "value": "x"]]], id: 2
        )
        #expect(throws: HarnessError.self) { try ChatReducer.reduce(state, patch) }
    }

    @Test func aQueuedRunsFramesLeaveTheActiveRunAlone() throws {
        var state = try Self.reduce([Self.started("r"), Self.snapshot(), Self.text("one")])
        // A queued turn's own stream opens with its place in the queue.
        state = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(
            ["type": "STATE_DELTA", "runId": "q", "delta": [["op": "add", "path": "/queue/-", "value": Self.queued("q")]]], id: 0
        ), runHint: "q")
        #expect(state.snapshot.queue.map(\.queueId) == ["q"])
        #expect(state.status == .streaming)
        #expect(state.runId == "r")
        // Its stream ends, cancelled, before the active run ends.
        state = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(Self.text("stray", message: "q-reply"), id: 1), runHint: "q")
        state = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(Self.finished("q"), id: 2), runHint: "q")
        #expect(state.messages.map(\.id) == ["m"])
        #expect(state.snapshot.queue.isEmpty)
        #expect(state.status == .streaming)
        #expect(state.cursors == ["r": 2, "q": 2])
    }

    @Test func aQueuedTurnThatFailsShowsWhyAndLeavesTheReplyStreaming() throws {
        var queued = try Self.reduce([Self.started("r"), Self.snapshot(), Self.text("one")])
        queued = try ChatReducer.reduce(queued, try HarnessProtocolFixtures.frame(
            ["type": "STATE_DELTA", "runId": "q", "delta": [["op": "add", "path": "/queue/-", "value": Self.queued("q")]]], id: 0
        ), runHint: "q")
        // The service shuts down before the queued turn starts. The failure
        // is not a reply's, so retrying sends the turn again rather than
        // running a reply again.
        let failure = try HarnessProtocolFixtures.frame(
            ["type": "RUN_ERROR", "threadId": "t", "runId": "q", "code": HarnessErrorCode.upstreamRefused, "message": "The service is shutting down", "action": "retry"], id: 1
        )
        let finished = try HarnessProtocolFixtures.frame(Self.finished("r"), id: 3)

        let streaming = try ChatReducer.reduce(queued, failure, runHint: "q")
        #expect(streaming.snapshot.queue.isEmpty)
        #expect(streaming.error?.code == HarnessErrorCode.upstreamRefused)
        #expect(streaming.status == .streaming)
        #expect(streaming.runId == "r")
        #expect(streaming.failedRun == nil)
        #expect(Self.blocks(streaming).first?.content == "one")
        // The chat shows why once the reply ends.
        let ended = try ChatReducer.reduce(streaming, finished)
        #expect(ended.status == .error)
        #expect(ended.error?.code == HarnessErrorCode.upstreamRefused)
        #expect(ended.failedRun == nil)

        // A queued turn that fails after the reply ended shows why at once.
        let idle = try ChatReducer.reduce(queued, finished)
        #expect(idle.status == .idle)
        let failed = try ChatReducer.reduce(idle, failure, runHint: "q")
        #expect(failed.status == .error)
        #expect(failed.error?.code == HarnessErrorCode.upstreamRefused)
        #expect(failed.failedRun == nil)
        #expect(failed.snapshot.queue.isEmpty)
    }

    @Test func aReplyRejoinedAfterItsStreamFailedEndsIdle() throws {
        // The stream broke and the chat showed the connection error; a
        // rejoin resumes after the frames applied, so RUN_STARTED is not
        // read again.
        var state = try Self.reduce([Self.started("r"), Self.snapshot(), Self.text("one")])
        state.status = .error
        state.error = HarnessErrorBody(code: HarnessErrorCode.streamInterrupted, message: "The connection closed.", action: .retry)
        state = try Self.reduce([Self.text(" two"), Self.finished("r")], from: 3, into: state)
        #expect(state.status == .idle)
        #expect(Self.blocks(state).first?.content == "one two")
    }

    @Test func aQueuedTurnTheRunningReplyListedFirstIsListedOnce() throws {
        var state = try Self.reduce([
            Self.started("r"), Self.snapshot(), Self.text("one"),
            ["type": "STATE_DELTA", "delta": [["op": "replace", "path": "/queue", "value": [Self.queued("q")]]]],
        ])
        state = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(
            ["type": "STATE_DELTA", "threadId": "t", "runId": "q", "delta": [["op": "add", "path": "/queue/-", "value": Self.queued("q")]]], id: 0
        ), runHint: "q")
        #expect(state.snapshot.queue.map(\.queueId) == ["q"])
        #expect(state.status == .streaming)
        #expect(state.runId == "r")
    }

    @Test func aRunTheUserStoppedNamesWhatItStoppedAsItEnds() throws {
        func ended(_ messages: [[String: Any]], stopping: Bool) throws -> (canceled: [String], state: ChatState) {
            var state = try Self.reduce([
                Self.started(),
                ["type": "MESSAGES_SNAPSHOT", "messages": [["id": "u", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "Why?"]], "hasOlder": false],
            ] + (messages.isEmpty ? [] : [Self.text("Half")]))
            state.stopping = stopping
            let frame = try HarnessProtocolFixtures.frame(
                ["type": "RUN_FINISHED", "threadId": "t", "runId": "r", "metadata": ["cancelled": true, "messages": messages]], id: 3
            )
            return (ChatReducer.canceled(by: frame.event, in: state), try ChatReducer.reduce(state, frame))
        }
        let reply = try ended([["id": "m", "isInterrupted": true]], stopping: true)
        #expect(reply.canceled == ["m"])
        #expect(!reply.state.stopping)
        // A run stopped before it answered leaves the message it stopped on.
        #expect(try ended([], stopping: true).canceled == ["u"])
        // The service stops replies too, as it restarts.
        #expect(try ended([["id": "m", "isInterrupted": true]], stopping: false).canceled.isEmpty)
    }

    @Test func aStateDeltaNamingARunQueuesAnIdleChat() throws {
        let state = try Self.reduce([
            ["type": "STATE_DELTA", "runId": "q", "delta": [["op": "replace", "path": "/queue", "value": [Self.queued("q")]]]],
        ])
        #expect(state.status == .queued)
        #expect(state.runId == "q")
    }

    @Test func aContinuationExtendsTheTrailingTextBlock() throws {
        let before = try Self.reduce([
            Self.started("r1"), Self.snapshot(), Self.reasoning("why"), Self.text("first"), Self.finished("r1"),
        ])
        let continued = try Self.reduce([Self.started("r2", messageId: "m"), Self.text(" and second")], into: before)
        #expect(Self.blocks(continued).map(\.content) == ["why", "first and second"])
        #expect(continued.continued == "m")
    }

    @Test func reasoningInAContinuationStartsNewBlocksAfterTheSealedOnes() throws {
        let before = try Self.reduce([
            Self.started("r1"), Self.snapshot(), Self.reasoning("why"), Self.text("first"), Self.finished("r1"),
        ])
        let continued = try Self.reduce([
            Self.started("r2", messageId: "m"), Self.reasoning("more"), Self.text("second"),
        ], into: before)
        #expect(Self.blocks(continued).map(\.content) == ["why", "first", "more", "second"])
    }

    @Test func textAfterASealedReplyStartsANewBlock() throws {
        let before = try Self.reduce([Self.started("r1"), Self.snapshot(), Self.text("first"), Self.finished("r1")])
        var sealed = before
        sealed.messages[0].timeline?.append(TimelineBlock(id: "tool", _type: .named(.toolCall), toolCallId: "tool", name: "web_search"))
        let continued = try Self.reduce([Self.started("r2", messageId: "m"), Self.text("second")], into: sealed)
        #expect(Self.blocks(continued).map(\.content) == ["first", nil, "second"])
    }

    @Test func aWidgetRetryAppliesOnlyItsToolEvents() throws {
        let before = try Self.reduce([
            Self.started("r1"), Self.snapshot(),
            ["type": "TOOL_CALL_START", "toolCallId": "w", "toolCallName": "render_clock", "parentMessageId": "m"],
            ["type": "TOOL_CALL_ARGS", "toolCallId": "w", "delta": "{bad"],
            ["type": "TOOL_CALL_END", "toolCallId": "w"],
            ["type": "TOOL_CALL_RESULT", "messageId": "m", "toolCallId": "w", "role": "tool", "content": ["status": "error"]],
            Self.finished("r1"),
        ])
        #expect(Self.blocks(before).first?.invalidArguments == true)
        let retry = try Self.frames([
            Self.started("r2"),
            ["type": "TOOL_CALL_START", "toolCallId": "w", "toolCallName": "render_clock", "parentMessageId": "m"],
            ["type": "TOOL_CALL_ARGS", "toolCallId": "w", "delta": "{}"],
            ["type": "TOOL_CALL_END", "toolCallId": "w"],
            ["type": "TOOL_CALL_RESULT", "messageId": "m", "toolCallId": "w", "role": "tool", "content": "[rendered for the user]"],
            Self.text("stray"),
            Self.finished("r2"),
        ]).reduce(before) { try ChatReducer.reduce($0, $1, runHint: "r2", widgetRetry: true) }
        let block = try #require(Self.blocks(retry).first)
        #expect(block.arguments == "{}")
        #expect(block.invalidArguments == nil)
        #expect(block.result?.value as? String == "[rendered for the user]")
        #expect(Self.blocks(retry).count == 1)
        #expect(retry.runId == "r1")
        #expect(retry.status == .idle)
    }

    @Test func activityGathersAToolsOutputOntoItsBlock() throws {
        let state = try Self.reduce([
            Self.started(), Self.snapshot(),
            ["type": "TOOL_CALL_START", "toolCallId": "s", "toolCallName": "web_search", "parentMessageId": "m"],
            ["type": "ACTIVITY_SNAPSHOT", "messageId": "act_s", "activityType": "TOOL",
             "content": ["toolCallId": "s", "tool": "web_search", "progress": 0.25, "output": ["Searching"]],
             "display": ["query": "cats", "status": "running", "sources": []]],
            ["type": "ACTIVITY_DELTA", "messageId": "act_s", "activityType": "TOOL",
             "patch": [["op": "replace", "path": "/progress", "value": 0.5], ["op": "add", "path": "/output/-", "value": "Found 2"]]],
        ])
        let block = try #require(Self.blocks(state).first)
        #expect(block.progress?.map { $0.value as? String } == ["Searching", "Found 2"])
        #expect((block.activity?.value as? [String: Any])?["progress"] as? Double == 0.5)
        #expect(block.display?.query == "cats")
    }

    @Test func aFlaggedChatsErrorMarksIt() throws {
        let state = try Self.reduce([
            Self.started(), Self.snapshot(),
            ["type": "RUN_ERROR", "threadId": "t", "runId": "r", "code": "CHAT_FLAGGED", "message": "flagged", "action": "stop"],
        ])
        #expect(state.flagged)
        #expect(state.status == .error)
        #expect(state.failedRun == "r")
        #expect(state.error?.code == "CHAT_FLAGGED")
    }

    @Test func aRunsEndCommitsWhatItReports() throws {
        let state = try Self.reduce([
            Self.started(), Self.snapshot(), Self.text("hi"),
            ["type": "RUN_FINISHED", "threadId": "t", "runId": "r", "metadata": [
                "messages": [["id": "m", "model": "gpt-oss-120b", "modelDisplayName": "GPT OSS", "usage": ["promptTokens": 3, "completionTokens": 1], "isError": false, "isInterrupted": false]],
            ]],
        ])
        let message = try #require(state.messages.first)
        #expect(message.model == "gpt-oss-120b")
        #expect(message.modelDisplayName == "GPT OSS")
        #expect(message.usage?.promptTokens == 3)
        #expect(state.status == .idle)
    }

    @Test func aMessagesSnapshotKeepsTheOlderPagesTheViewLoaded() throws {
        var view = ChatState()
        view.messages = [
            HarnessMessage(id: "old", role: .named(.user), createdAt: "", content: "old"),
            HarnessMessage(id: "m1", role: .named(.user), createdAt: "", content: "first"),
        ]
        view.hasOlder = true
        let state = try Self.reduce([
            Self.started(),
            ["type": "MESSAGES_SNAPSHOT", "messages": [["id": "m1", "role": "user", "createdAt": "", "content": "first"]], "hasOlder": false],
        ], into: view)
        #expect(state.messages.map(\.id) == ["old", "m1"])
        #expect(state.hasOlder)
    }

    @Test func aMessagesSnapshotStartingBelowAMarkerKeepsIt() throws {
        var view = ChatState()
        view.messages = [HarnessMessage(id: "m1", role: .named(.user), createdAt: "", content: "first")]
        view.markers = ["m1": HarnessMessage(id: "c", role: .named(.compaction), createdAt: "", content: Self.summary)]
        let state = try Self.reduce([
            Self.started(),
            ["type": "MESSAGES_SNAPSHOT", "messages": [["id": "m1", "role": "user", "createdAt": "", "content": "first"]], "hasOlder": true],
        ], into: view)
        #expect(state.markers["m1"]?.id == "c")
    }

    private static let summary = "## Goals and context\nThe user asked a first question."

    private static func marker(_ id: String = "c", covering messages: Int = 2) -> [String: Any] {
        ["id": id, "role": "compaction", "createdAt": "2026-01-01T00:00:03Z", "content": summary,
         "compaction": ["messages": messages, "startedAt": 1767225600000, "endedAt": 1767225601000, "model": "gpt-oss-120b", "version": 1]]
    }

    /// The messages of a chat whose compaction keeps its latest exchange, u2
    /// and a2, before the run's question.
    private static let compactedMessages: [[String: Any]] = [
        ["id": "u1", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "first"],
        ["id": "a1", "role": "assistant", "createdAt": "2026-01-01T00:00:01Z", "timeline": [["id": "b1", "type": "content", "content": "long"]]],
        ["id": "u2", "role": "user", "createdAt": "2026-01-01T00:00:02Z", "content": "second"],
        ["id": "a2", "role": "assistant", "createdAt": "2026-01-01T00:00:02Z", "timeline": [["id": "b2", "type": "content", "content": "short"]]],
        ["id": "u3", "role": "user", "createdAt": "2026-01-01T00:00:02Z", "content": "third"],
    ]

    private static let compactedTurn: [[String: Any]] = [
        started(),
        ["type": "MESSAGES_SNAPSHOT", "messages": compactedMessages, "hasOlder": false],
        snapshot(),
        compactionStart(),
    ]

    private static func compactionStart(before: String = "u2") -> [String: Any] {
        ["type": "COMPACTION_START", "timestamp": "2026-01-01T00:00:03Z", "messageId": "c", "beforeMessageId": before]
    }

    private static func compactionEnd(_ outcome: String, marker: [String: Any]? = nil, before: String = "u2") -> [String: Any] {
        var event: [String: Any] = ["type": "COMPACTION_END", "messageId": "c", "beforeMessageId": before, "outcome": outcome]
        if let marker { event["marker"] = marker }
        return event
    }

    @Test func aCompactionOpensAboveTheMessageItNamesAndKeepsTheMarkerItCompletes() throws {
        let running = try Self.reduce(Self.compactedTurn)
        #expect(running.messages.map(\.id) == ["u1", "a1", "u2", "a2", "u3"])
        let open = try #require(running.markers["u2"])
        #expect(open.id == "c")
        #expect(open.compaction == nil)
        #expect(open.createdAt == "2026-01-01T00:00:03Z")
        // The messages above a summary still being written are still read.
        #expect(running.summarizedIds.isEmpty)

        let completed = try Self.reduce([Self.compactionEnd("completed", marker: Self.marker())], from: Self.compactedTurn.count, into: running)
        #expect(completed.messages.map(\.id) == ["u1", "a1", "u2", "a2", "u3"])
        let marker = try #require(completed.markers["u2"])
        #expect(marker.content == Self.summary)
        #expect(marker.compaction?.messages == 2)
        // The exchange the compaction kept is still read.
        #expect(completed.summarizedIds == ["u1", "a1"])
        #expect(completed.messagesWithMarkers.map(\.id) == ["u1", "a1", "c", "u2", "a2", "u3"])
        // The chat points out the compaction it just showed complete.
        #expect(running.compacted == nil)
        #expect(completed.compacted == "c")
    }

    @Test func aCompletedCompactionWhoseOpeningANewWindowReplacedKeepsItsPlace() throws {
        let state = try Self.reduce(Self.compactedTurn + [
            ["type": "MESSAGES_SNAPSHOT", "messages": Self.compactedMessages, "hasOlder": false],
            Self.compactionEnd("completed", marker: Self.marker()),
        ])
        #expect(state.markers.mapValues(\.id) == ["u2": "c"])
    }

    @Test func aFailedCompactionRemovesItsMarkerBeforeTheRunFails() throws {
        for outcome in ["failed", "abandoned"] {
            let state = try Self.reduce(Self.compactedTurn + [
                Self.compactionEnd(outcome),
                ["type": "RUN_ERROR", "threadId": "t", "runId": "r", "code": HarnessErrorCode.compactionFailed, "message": "failed", "action": "retry"],
            ])
            #expect(state.markers.isEmpty, "\(outcome)")
            #expect(state.compacted == nil, "\(outcome)")
            #expect(state.messages.map(\.id) == ["u1", "a1", "u2", "a2", "u3"])
            #expect(state.status == .error)
            #expect(state.error?.code == HarnessErrorCode.compactionFailed)
            #expect(state.error?.action == .retry)
        }
    }

    @Test func aReplayedCompactionChangesNothing() throws {
        let events = Self.compactedTurn + [Self.compactionEnd("completed", marker: Self.marker())]
        let state = try Self.reduce(events)
        // A run followed again from its first frame skips what it applied.
        #expect(try Self.reduce(events, into: state) == state)
        // Its end applied once more keeps the one marker where it was.
        let again = try ChatReducer.reduce(state, try HarnessProtocolFixtures.frame(Self.compactionEnd("completed", marker: Self.marker())))
        #expect(again.markers == state.markers)
    }

    @Test func aChatHasSomethingToCompactBeforeItsLastQuestionAfterItsLatestMarker() throws {
        let snapshot: [String: Any] = ["type": "MESSAGES_SNAPSHOT", "messages": Self.compactedMessages, "hasOlder": false]
        #expect(try Self.reduce([Self.started(), snapshot]).compactable)
        // The marker above u2 leaves u2 and its reply before the last
        // question, which a marker above that question does not.
        #expect(try Self.reduce(Self.compactedTurn + [Self.compactionEnd("completed", marker: Self.marker())]).compactable)
        let aboveQuestion = Self.compactedTurn.dropLast() + [Self.compactionStart(before: "u3"), Self.compactionEnd("completed", marker: Self.marker(), before: "u3")]
        #expect(try !Self.reduce(Array(aboveQuestion)).compactable)
        let onlyQuestion: [String: Any] = ["type": "MESSAGES_SNAPSHOT", "messages": Array(Self.compactedMessages.prefix(1)), "hasOlder": false]
        #expect(try !Self.reduce([Self.started(), onlyQuestion]).compactable)
    }

    @Test func aCompactionTheChatAskedForIsItsRunUntilItEndsAndOneThatFailedIsKeptToRetry() throws {
        var submitted = ChatState()
        submitted.status = .submitting
        submitted.compactTurn = true
        let compacting = try Self.reduce([Self.started("compact")], into: submitted)
        #expect(compacting.status == .streaming)
        #expect(compacting.compactTurn)

        let compacted = try Self.reduce([Self.finished("compact")], from: 1, into: compacting)
        let failed = try Self.reduce([
            ["type": "RUN_ERROR", "threadId": "t", "runId": "compact", "code": HarnessErrorCode.compactionFailed, "message": "failed", "action": "retry"],
        ], from: 1, into: compacting)

        #expect(!compacted.compactTurn)
        #expect(failed.status == .error)
        #expect(failed.compactTurn)
        // A turn queued behind the failed compaction streams its own reply.
        let replying = try Self.reduce([Self.started("queued")], into: failed)
        #expect(replying.runId == "queued")
        #expect(!replying.compactTurn)
    }

    @Test func aStoppedCompactionCancelsNoQuestionItLeftUnanswered() throws {
        var stopping = try Self.reduce([Self.started(), ["type": "MESSAGES_SNAPSHOT", "messages": Self.compactedMessages, "hasOlder": false]])
        stopping.stopping = true
        let stopped = try HarnessProtocolFixtures.frame(["type": "RUN_FINISHED", "threadId": "t", "runId": "r", "metadata": ["cancelled": true, "messages": []]]).event
        #expect(ChatReducer.canceled(by: stopped, in: stopping) == ["u3"])

        stopping.compactTurn = true

        #expect(ChatReducer.canceled(by: stopped, in: stopping).isEmpty)
    }

    @Test func aCompactionBeforeAMessageTheChatLacksShowsNoMarker() throws {
        var events = Self.compactedTurn
        events[events.count - 1] = Self.compactionStart(before: "gone")
        let state = try Self.reduce(events + [Self.compactionEnd("completed", marker: Self.marker(), before: "gone")])
        #expect(state.markers.isEmpty)
    }

    @Test func aLoadedChatShowsItsMarkersAboveTheirQuestionsAndNotAsMessages() throws {
        let messages: [[String: Any]] = [
            ["id": "u1", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "first"],
            ["id": "a1", "role": "assistant", "createdAt": "2026-01-01T00:00:01Z", "timeline": []],
            Self.marker(),
            ["id": "u2", "role": "user", "createdAt": "2026-01-01T00:00:04Z", "content": "second"],
            ["id": "a2", "role": "assistant", "createdAt": "2026-01-01T00:00:05Z", "timeline": []],
        ]
        var window = Self.thread
        window.merge(["revision": "1", "presetId": NSNull(), "messages": messages, "hasOlder": false]) { $1 }
        let loaded = ChatState(thread: try ThreadWindow(jsonObject: window))
        #expect(loaded.messages.map(\.id) == ["u1", "a1", "u2", "a2"])
        #expect(loaded.markers.mapValues(\.id) == ["u2": "c"])
        #expect(loaded.summarizedIds == ["u1", "a1"])
    }

    @Test func aWindowThatStartsBelowAMarkerKeepsTheMarkerTheViewLoaded() throws {
        var view = ChatState()
        view.messages = [
            HarnessMessage(id: "old", role: .named(.user), createdAt: "", content: "old"),
            HarnessMessage(id: "m1", role: .named(.user), createdAt: "", content: "first"),
        ]
        view.markers = ["m1": try HarnessMessage(jsonObject: Self.marker())]
        view.hasOlder = true
        let state = try Self.reduce([
            Self.started(),
            ["type": "MESSAGES_SNAPSHOT", "messages": [["id": "m1", "role": "user", "createdAt": "", "content": "first"]], "hasOlder": true],
        ], into: view)
        #expect(state.messagesWithMarkers.map(\.id) == ["old", "c", "m1"])
    }
}
