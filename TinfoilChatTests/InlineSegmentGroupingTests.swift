import Testing
@testable import TinfoilChat

@MainActor
struct InlineSegmentGroupingTests {
    private func runs(_ segments: [MessageSegment]) -> [MessageView.IdentifiedInlineSegmentRun] {
        var message = Message(role: .assistant, content: "")
        message.webSearches = ["first", "second", "third"].map {
            WebSearchInstance(id: $0, query: "query-\($0)", status: .completed, sources: [], reason: nil)
        }
        return MessageView.inlineSegmentRuns(from: segments, message: message)
    }

    @Test func groupsSearchesAcrossThinkingAndWhitespace() {
        let result = runs([
            .webSearch(searchId: "first"),
            .text("\n\n"),
            .thinking(content: "Compare", isThinking: false, duration: 3),
            .webSearch(searchId: "second"),
            .thinking(content: "Verify", isThinking: true, duration: nil),
            .webSearch(searchId: "third"),
            .text("Answer"),
        ])
        #expect(result.count == 3)
        guard case .webSearches(let searches) = result.first?.run,
              case .thinking(let content, let active, let duration) = result.dropFirst().first?.run else {
            Issue.record("Expected one search group and one thinking row")
            return
        }
        #expect(searches.map(\.id) == ["first", "second", "third"])
        #expect(searches.map(\.query) == ["query-first", "query-second", "query-third"])
        #expect(content == "Compare\n\nVerify")
        #expect(active)
        #expect(duration == 3)
    }

    @Test func visibleTextAndToolsSeparateSearchGroups() {
        let boundaries: [MessageSegment] = [.text("Interim answer"), .toolCall(toolCallId: "widget"), .urlFetch(fetchId: "page")]
        for boundary in boundaries {
            let result = runs([.webSearch(searchId: "first"), boundary, .webSearch(searchId: "second")])
            let sizes = result.compactMap { run -> Int? in
                guard case .webSearches(let group) = run.run else { return nil }
                return group.count
            }
            #expect(sizes == [1, 1])
        }
    }

    @Test func growingSearchGroupKeepsItsIdentity() {
        let first = runs([.webSearch(searchId: "first")])
        let expanded = runs([.webSearch(searchId: "first"), .webSearch(searchId: "second")])
        #expect(first.first?.id == expanded.first?.id)
    }
}
