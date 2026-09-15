import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

struct WebSearchHistoryTests {
    private let url = "https://example.com/paper?edition=2#results"
    private let excerpt = "The retrieved paper reports a sample of 73 participants."

    private func message() -> Message {
        Message(role: .assistant, content: "Answer.", webSearchState: WebSearchState(
            query: "sample size", status: .completed,
            sources: [WebSearchSource(title: "Paper", url: url, snippet: excerpt)]
        ))
    }

    private func objects(_ messages: [ChatQuery.ChatCompletionMessageParam]) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)) as? [[String: Any]])
    }

    @Test func replaysPairedEvidenceAfterSixStoredTurns() throws {
        for index in 0..<6 {
            let restored = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message()))
            let replay = try objects(WebSearchHistory.messages(for: restored, messageIndex: index))
            #expect(replay.count == 2)
            let calls = try #require(replay[0]["tool_calls"] as? [[String: Any]])
            #expect(replay[0]["role"] as? String == "assistant")
            #expect(replay[1]["role"] as? String == "tool")
            #expect(calls[0]["id"] as? String == replay[1]["tool_call_id"] as? String)
            #expect(calls[0]["id"] as? String == "saved_web_\(index)_0")
            let output = try #require(replay[1]["content"] as? String)
            #expect(output.contains(excerpt))
        }
    }

    @Test func preservesExcerptsAcrossWebTimelineRoundTrip() throws {
        var original = message()
        let source = WebSearchSource(title: "Paper", url: url, snippet: excerpt)
        original.webSearches = [WebSearchInstance(id: "search", query: "sample size", status: .completed, sources: [source], reason: nil)]
        original.urlFetches = [URLFetchState(id: "fetch", url: url, status: .completed, sources: [source])]
        original.segments = [.webSearch(searchId: "search"), .urlFetch(fetchId: "fetch"), .text("Answer.")]
        let timeline = try #require(original.buildSyncTimeline())
        let webMessage: [String: Any] = ["role": "assistant", "content": "Answer.", "timestamp": "2026-09-01T00:00:00Z", "timeline": try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline))]
        let restored = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: webMessage))
        #expect(restored.webSearches?.first?.sources?.first?.snippet == excerpt)
        #expect(restored.urlFetches.first?.sources?.first?.snippet == excerpt)
        let replay = try objects(WebSearchHistory.messages(for: restored, messageIndex: 0))
        #expect(replay.count == 4)
        let fetchOutput = try #require(replay[3]["content"] as? String)
        #expect(fetchOutput.contains(excerpt))
    }

    @Test func excludesUnsupportedEvidenceAndBoundsHistory() throws {
        var original = message()
        for status in [WebSearchStatus.searching, .failed, .blocked] {
            original.webSearchState?.status = status
            #expect(WebSearchHistory.messages(for: original, messageIndex: 0).isEmpty)
        }
        original.webSearchState?.status = .completed
        original.webSearchState?.sources = [WebSearchSource(title: "Legacy", url: url)]
        #expect(WebSearchHistory.messages(for: original, messageIndex: 0).isEmpty)
        let largeSnippet = String(repeating: "🔎", count: 2000)
        original.webSearches = (0..<20).map { index in
            WebSearchInstance(id: "search-\(index)", query: "query-\(index)", status: .completed,
                              sources: (0..<8).map { WebSearchSource(title: "Paper", url: "\(url)-\($0)", snippet: largeSnippet) }, reason: nil)
        }
        let replay = WebSearchHistory.messages(for: original, messageIndex: 0)
        #expect(!replay.isEmpty)
        #expect(WebSearchHistory.serializedLength(replay) <= Constants.WebSearchHistory.maxSerializedCharacters)
        #expect(TokenEstimation.estimateMessageTokens(original) > TokenEstimation.estimateTokenCount(original.content))
        let encoded = try #require(String(data: JSONEncoder().encode(replay), encoding: .utf8))
        #expect(encoded.contains("query-19"))
        #expect(encoded.contains("[Excerpt truncated]"))
    }

    @Test func sourceMetadataSurvivesCitationUpdates() throws {
        let processor = StreamingResponseProcessor(isWebSearchEnabled: true, hapticEnabled: false)
        processor.upsertWebSearch(WebSearchInstance(id: "search", query: "sample size", status: .completed,
            sources: [WebSearchSource(title: "Paper", url: url, snippet: excerpt)], reason: nil))
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-test", "object": "chat.completion.chunk", "created": 1, "model": "gpt-oss-120b",
            "choices": [["index": 0, "finish_reason": "stop", "delta": ["annotations": [["type": "url_citation", "url_citation": ["url": url, "title": "Paper", "start_index": 0, "end_index": 1]]]]]]
        ])
        let chunk = try JSONDecoder().decode(ChatStreamResult.self, from: data)
        _ = processor.process(processor.parse(chunk))
        try processor.finishStream()
        #expect(processor.snapshot().webSearches.first?.sources?.first?.snippet == excerpt)
        #expect(processor.findSearchInstance(matching: "different-search") == nil)
    }
}
