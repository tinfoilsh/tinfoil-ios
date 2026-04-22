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
}
