//
//  MessageSegmentDecodeTests.swift
//  TinfoilChatTests
//
//  Verifies Message JSON decoding is forward-compatible: a message whose
//  `segments` array contains unknown segment types (e.g. added by a future
//  client version) still decodes successfully, with unknown entries
//  dropped rather than failing the whole message.
//

import Foundation
import Testing
@testable import TinfoilChat

struct MessageSegmentDecodeTests {

    @Test func decodesMessageWithMixOfKnownAndUnknownSegments() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "hello",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "segments": [
            { "type": "text", "text": "hi" },
            { "type": "future_tool_call", "foo": "bar" },
            { "type": "web_search", "searchId": "ws_1" },
            { "type": "another_unknown", "data": { "nested": true } },
            { "type": "url_fetch", "fetchId": "uf_1" }
          ]
        }
        """

        let data = Data(json.utf8)
        let message = try JSONDecoder().decode(Message.self, from: data)
        let segments = try #require(message.segments)

        #expect(segments.count == 3)
        #expect(segments[0] == .text("hi"))
        #expect(segments[1] == .webSearch(searchId: "ws_1"))
        #expect(segments[2] == .urlFetch(fetchId: "uf_1"))
    }

    @Test func decodesMessageWhenSegmentsArrayIsMissing() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "hello",
          "timestamp": "2026-04-21T12:00:00.000Z"
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.segments == nil)
    }

    @Test func decodesMessageWhenAllSegmentsAreUnknown() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "hello",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "segments": [
            { "type": "future_a" },
            { "type": "future_b", "extra": 1 }
          ]
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.segments?.isEmpty == true)
    }

    @Test @MainActor
    func decodesAndPreservesGenUIToolCalls() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "toolCalls": [
            {
              "id": "call_1",
              "name": "render_info_card",
              "arguments": "{\\"title\\":\\"Hello\\"}"
            }
          ],
          "timeline": [
            {
              "type": "tool_call",
              "id": "tool-call-0",
              "toolCallId": "call_1",
              "name": "render_info_card",
              "arguments": "{\\"title\\":\\"Hello\\"}"
            }
          ]
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.hasUnsupportedGenUI)
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls[0].name == "render_info_card")

        let encoded = try JSONEncoder().encode(message)
        let roundTripped = try JSONDecoder().decode(Message.self, from: encoded)
        #expect(roundTripped.hasUnsupportedGenUI)
        #expect(roundTripped.toolCalls == message.toolCalls)
        #expect(roundTripped.timeline == message.timeline)
    }

    @Test @MainActor
    func detectsUnsupportedGenUIFromTimelineWhenToolCallsAreMissing() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "timeline": [
            { "type": "content", "id": "content-0", "content": "" },
            {
              "type": "tool_call",
              "id": "tool-call-1",
              "toolCallId": "call_1",
              "name": "render_future_widget",
              "arguments": "{\\"foo\\":\\"bar\\"}"
            }
          ]
        }
        """

        // Webapp-synced messages omit the flat `toolCalls` array but still
        // carry tool calls on the timeline. iOS derives `toolCalls` from
        // the timeline so the unsupported-widget notice fires regardless
        // of which client wrote the message.
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls[0].name == "render_future_widget")
        #expect(message.hasUnsupportedGenUI)
    }

    @Test @MainActor
    func registeredGenUIToolCallIsNotMarkedUnsupported() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "toolCalls": [
            {
              "id": "call_1",
              "name": "render_link_preview",
              "arguments": "{\\"url\\":\\"https://example.com\\",\\"title\\":\\"Example\\"}"
            }
          ]
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.toolCalls.count == 1)
        #expect(!message.hasUnsupportedGenUI)
    }

    @Test @MainActor
    func derivesSegmentsAndWebSearchesFromTimeline() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "Done.",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "timeline": [
            { "type": "thinking", "id": "t-0", "content": "Reasoning...", "isThinking": false, "duration": 1.5 },
            {
              "type": "web_search",
              "id": "ws-0",
              "state": {
                "query": "weather",
                "status": "completed",
                "sources": [{ "title": "Example", "url": "https://example.com" }]
              }
            },
            { "type": "content", "id": "c-0", "content": "Looking up weather." },
            {
              "type": "tool_call",
              "id": "tc-0",
              "toolCallId": "call_1",
              "name": "render_clock",
              "arguments": "{\\"label\\":\\"NYC\\"}"
            },
            { "type": "content", "id": "c-1", "content": "Done." }
          ]
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        let segments = try #require(message.segments)
        #expect(segments.count == 5)
        if case .thinking(let content, _, let duration) = segments[0] {
            #expect(content == "Reasoning...")
            #expect(duration == 1.5)
        } else {
            Issue.record("Expected first segment to be thinking, got \(segments[0])")
        }
        #expect(segments[1] == .webSearch(searchId: "ws-0"))
        #expect(segments[2] == .text("Looking up weather."))
        #expect(segments[3] == .toolCall(toolCallId: "call_1"))
        #expect(segments[4] == .text("Done."))

        let webSearches = try #require(message.webSearches)
        #expect(webSearches.count == 1)
        #expect(webSearches[0].id == "ws-0")
        #expect(webSearches[0].query == "weather")
        #expect(webSearches[0].sources?.first?.url == "https://example.com")

        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls[0].name == "render_clock")
    }

    @Test @MainActor
    func readsResolutionFromTimelineToolCallBlock() throws {
        let resolvedAtMillis: Int = 1_714_060_800_000
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "content": "",
          "timestamp": "2026-04-21T12:00:00.000Z",
          "toolCalls": [
            { "id": "call_1", "name": "ask_user_input", "arguments": "{}" }
          ],
          "timeline": [
            {
              "type": "tool_call",
              "id": "tool-call-0",
              "toolCallId": "call_1",
              "name": "ask_user_input",
              "arguments": "{}",
              "resolvedAt": \(resolvedAtMillis),
              "resolution": { "text": "Yes", "data": { "choice": "yes" } }
            }
          ]
        }
        """

        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        let resolution = try #require(message.genUIResolution(for: "call_1"))
        #expect(resolution.text == "Yes")
        let expectedDate = Date(timeIntervalSince1970: TimeInterval(resolvedAtMillis) / 1000)
        #expect(abs(resolution.resolvedAt.timeIntervalSince(expectedDate)) < 0.001)
    }
}
