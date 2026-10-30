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
        #expect(state.snapshot.thread?.titleState == .generated)
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
        sealed.messages[0].timeline?.append(TimelineBlock(id: "tool", _type: .toolCall, toolCallId: "tool", name: "web_search"))
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
            HarnessMessage(id: "old", role: .user, createdAt: "", content: "old"),
            HarnessMessage(id: "m1", role: .user, createdAt: "", content: "first"),
        ]
        view.hasOlder = true
        let state = try Self.reduce([
            Self.started(),
            ["type": "MESSAGES_SNAPSHOT", "messages": [["id": "m1", "role": "user", "createdAt": "", "content": "first"]], "hasOlder": false],
        ], into: view)
        #expect(state.messages.map(\.id) == ["old", "m1"])
        #expect(state.hasOlder)
    }
}
