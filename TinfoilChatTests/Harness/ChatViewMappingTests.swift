import Foundation
import OpenAPIRuntime
import Testing
@testable import TinfoilChat

@Suite("Chat view mapping")
struct ChatViewMappingTests {
    private static func message(_ object: [String: Any]) throws -> HarnessMessage {
        try HarnessMessage(jsonObject: object)
    }

    private static func reply(_ timeline: [[String: Any]]) throws -> HarnessMessage {
        try message(["id": "m", "role": "assistant", "createdAt": "2026-01-01T00:00:00Z", "timeline": timeline])
    }

    @Test func aReplyStillThinkingHasNoSettledThinkingTime() throws {
        // The chat service updates a thought's duration as it streams.
        let wire = try Self.reply([["id": "t1", "type": "thinking", "content": "Hmm", "duration": 2.0, "startedAt": 1000, "endedAt": 3000]])
        let live = ChatViewMapping.message(wire, streaming: true)
        #expect(live.isThinking)
        #expect(live.generationTimeSeconds == nil)
        let settled = ChatViewMapping.message(wire, streaming: false)
        #expect(!settled.isThinking)
        #expect(settled.generationTimeSeconds == 2.0)
    }

    @Test func aReplysBlocksBecomeItsTextThoughtsAndSegments() throws {
        let wire = try Self.reply([
            ["id": "t1", "type": "thinking", "content": "why", "duration": 1.5, "startedAt": 1000, "endedAt": 2500],
            ["id": "c1", "type": "content", "content": "Hello "],
            ["id": "c2", "type": "content", "content": "world"],
        ])
        let shown = ChatViewMapping.message(wire, streaming: false, summaries: ["t1": "Thinking about it"])
        #expect(shown.role == .assistant)
        #expect(shown.content == "Hello world")
        #expect(shown.thoughts == "why")
        #expect(shown.thinkingDuration == 1.5)
        #expect(shown.isThinking == false)
        #expect(shown.segments == [
            .thinking(content: "why", isThinking: false, duration: 1.5, startedAt: 1000),
            .text("Hello "),
            .text("world"),
        ])
        #expect(shown.timeline?.first?.objectValue?["summary"]?.stringValue == "Thinking about it")
    }

    @Test func aStreamingReplyThinksOnlyInItsLastBlock() throws {
        let thinkingLast = try Self.reply([
            ["id": "c1", "type": "content", "content": "So far"],
            ["id": "t1", "type": "thinking", "content": "more"],
        ])
        #expect(ChatViewMapping.message(thinkingLast, streaming: true).isThinking)
        #expect(!ChatViewMapping.message(thinkingLast, streaming: false).isThinking)
        let textLast = try Self.reply([
            ["id": "t1", "type": "thinking", "content": "first"],
            ["id": "c1", "type": "content", "content": "then"],
        ])
        #expect(!ChatViewMapping.message(textLast, streaming: true).isThinking)
        #expect(ChatViewMapping.message(textLast, streaming: true).isStreaming)
    }

    @Test func searchesAndPageReadsShowWhatTheHarnessReports() throws {
        let wire = try Self.reply([
            ["id": "s", "type": "tool_call", "toolCallId": "s", "name": "web_search", "arguments": #"{"query":"cats"}"#, "complete": true,
             "display": ["query": "cats", "status": "completed", "sources": [["url": "https://cats.test", "title": "Cats", "snippet": "All about cats."]]]],
            ["id": "f", "type": "tool_call", "toolCallId": "f", "name": "web_fetch", "arguments": #"{"urls":["https://a.test","https://b.test"]}"#, "complete": true,
             "result": ["failed": [["url": "https://b.test", "error": "timeout"]]],
             "display": ["status": "completed", "sources": [["url": "https://a.test", "title": "A"]]]],
            ["id": "c", "type": "content", "content": "Found it."],
        ])
        let shown = ChatViewMapping.message(wire)
        let search = try #require(shown.webSearches?.first)
        #expect(search.query == "cats")
        #expect(search.status == .completed)
        #expect(search.sources?.map(\.title) == ["Cats"])
        #expect(shown.urlFetches.map(\.url) == ["https://a.test", "https://b.test"])
        #expect(shown.urlFetches.map(\.status) == [.completed, .failed])
        #expect(shown.segments == [.webSearch(searchId: "s"), .urlFetch(fetchId: "f"), .urlFetch(fetchId: "f-1"), .text("Found it.")])
    }

    @Test func aToolStillRunningOnceTheReplyStoppedWasCutOff() throws {
        let wire = try Self.reply([
            ["id": "s", "type": "tool_call", "toolCallId": "s", "name": "web_search", "arguments": "{}", "display": ["status": "running", "sources": []]],
        ])
        #expect(ChatViewMapping.message(wire, streaming: true).webSearches?.first?.status == .searching)
        #expect(ChatViewMapping.message(wire, streaming: false).webSearches?.first?.status == .failed)
    }

    @Test func widgetsAreShownAndOtherToolsAreNot() throws {
        let wire = try Self.reply([
            ["id": "w", "type": "tool_call", "toolCallId": "w", "name": "render_clock", "arguments": #"{"tz":"UTC"}"#, "complete": true],
            ["id": "h", "type": "tool_call", "toolCallId": "h", "name": "hidden_tool", "arguments": "{}", "complete": true],
        ])
        let shown = ChatViewMapping.message(wire)
        #expect(shown.toolCalls == [GenUIToolCall(id: "w", name: "render_clock", arguments: #"{"tz":"UTC"}"#)])
        #expect(shown.segments == [.toolCall(toolCallId: "w")])
    }

    @Test func aUserMessageKeepsItsTextAndAttachments() throws {
        let wire = try Self.message([
            "id": "u", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "Look",
            "attachments": [["id": "a", "kind": "image", "fileName": "cat.png", "mimeType": "image/png", "size": 12, "thumbnail": "AAAA"]],
        ])
        let shown = ChatViewMapping.message(wire)
        #expect(shown.role == .user)
        #expect(shown.content == "Look")
        #expect(shown.attachments.map(\.fileName) == ["cat.png"])
        #expect(shown.attachments.first?.type == .image)
        #expect(shown.attachments.first?.thumbnailBase64 == "AAAA")
        #expect(shown.attachments.first?.processingState == .completed)
    }

    @Test func aBlockOfATypeThisClientDoesNotKnowIsLeftOut() throws {
        let wire = try Self.reply([
            ["id": "x", "type": "diagram", "content": "<svg/>"],
            ["id": "c", "type": "content", "content": "Done."],
        ])
        let shown = ChatViewMapping.message(wire)
        #expect(shown.content == "Done.")
        #expect(shown.segments == [.text("Done.")])
    }

    @Test func aToolStatusThisClientDoesNotKnowShowsAsCompleted() throws {
        let wire = try Self.reply([
            ["id": "s", "type": "tool_call", "toolCallId": "s", "name": "web_search", "arguments": "{}", "complete": true,
             "display": ["query": "cats", "status": "cached", "sources": []]],
        ])
        #expect(ChatViewMapping.message(wire, streaming: true).webSearches?.first?.status == .completed)
    }

    @Test func anAttachmentOfAKindThisClientDoesNotKnowShowsAsAFile() throws {
        let wire = try Self.message([
            "id": "u", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "Watch",
            "attachments": [["id": "a", "kind": "video", "fileName": "cat.mp4", "mimeType": "video/mp4", "size": 12]],
        ])
        #expect(ChatViewMapping.message(wire).attachments.first?.type == .document)
    }

    @Test func aTitleOfAStateThisClientDoesNotKnowShowsAsItIs() throws {
        let summary = try ThreadSummary(jsonObject: [
            "id": "t", "title": "New Chat", "titleState": "translated", "activityAt": "2026-01-01T00:00:00Z",
            "model": "auto", "webSearchEnabled": true, "pinned": false, "messageCount": 2,
        ])
        let chat = ChatViewMapping.chat(summary, local: false)
        #expect(chat.title == "New Chat")
        #expect(chat.titleState == .manual)
    }

    @Test func aChatWaitingForItsTitleShowsTheDefaultOne() throws {
        var summary = try ThreadSummary(jsonObject: [
            "id": "t", "title": "New Chat", "titleState": "placeholder", "activityAt": "2026-01-01T00:00:00Z",
            "model": "auto", "webSearchEnabled": true, "pinned": true, "messageCount": 2,
            "contextUsage": ["usedTokens": 10, "limitTokens": 100, "percentage": 10],
            "activeRun": ["runId": "r", "expiresAt": "2026-01-01T00:01:00Z", "instance": "i"],
        ])
        var chat = ChatViewMapping.chat(summary, local: false, presetId: "user:p")
        #expect(chat.title == Chat.defaultTitle)
        #expect(chat.titleState == .placeholder)
        #expect(chat.pinned)
        #expect(chat.messageCount == 2)
        #expect(!chat.isBlankChat)
        #expect(chat.promptPresetId == "user:p")
        #expect(chat.contextUsage == ContextUsage(percentage: 10, usedTokens: 10, limitTokens: 100))
        #expect(chat.activeRun?.runId == "r")
        summary.title = "Cats"
        summary.titleState = .named(.generated)
        chat = ChatViewMapping.chat(summary, local: true)
        #expect(chat.title == "Cats")
        #expect(chat.isLocalOnly)
    }

    @Test func aListedRunIsLiveUntilItsDeadline() throws {
        let deadline = try #require(ChatAccessCache.date(of: "2026-01-01T00:01:00Z"))
        let listed = ActiveRun(runId: "r", expiresAt: "2026-01-01T00:01:00Z", instance: "i")
        #expect(listed.isLive(at: deadline.addingTimeInterval(-1)))
        #expect(!listed.isLive(at: deadline))
        // A run this app streams is live without a deadline.
        #expect(ActiveRun(runId: "r", expiresAt: "", instance: "").isLive(at: deadline))
    }
}
