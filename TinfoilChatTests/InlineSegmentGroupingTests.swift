import Testing
@testable import TinfoilChat

@MainActor
struct InlineSegmentGroupingTests {
    private func runs(_ segments: [MessageSegment]) -> [MessageView.IdentifiedInlineSegmentRun] {
        var message = Message(role: .assistant, content: "")
        message.webSearches = ["first", "second", "third"].map {
            WebSearchInstance(id: $0, query: "query-\($0)", status: .completed, sources: [], reason: nil)
        }
        message.urlFetches = [URLFetchState(id: "page", url: "https://example.com/page", status: .completed)]
        return MessageView.inlineSegmentRuns(from: segments, message: message)
    }

    private func workSteps(_ run: MessageView.IdentifiedInlineSegmentRun?) -> [WorkStep]? {
        guard case .work(let work) = run?.run else { return nil }
        return work.steps
    }

    @Test func collapsesSearchesAndThinkingIntoOneWorkRunAcrossWhitespace() {
        let result = runs([
            .webSearch(searchId: "first"),
            .text("\n\n"),
            .thinking(content: "Compare", isThinking: false, duration: 3),
            .webSearch(searchId: "second"),
            .thinking(content: "Verify", isThinking: true, duration: nil),
            .webSearch(searchId: "third"),
            .text("Answer"),
        ])
        #expect(result.count == 2)
        guard let steps = workSteps(result.first),
              case .text(let answer, let isTrailing) = result.last?.run else {
            Issue.record("Expected one work run followed by the answer, got \(result.map(\.id))")
            return
        }
        #expect(result.first?.id == "work:0:searches:first")
        #expect(answer == "Answer")
        #expect(isTrailing)
        #expect(steps.count == 5)
        guard case .webSearches(let a) = steps[0],
              case .thinking(let compare, let compareActive, let compareDuration, _, _) = steps[1],
              case .webSearches(let b) = steps[2],
              case .thinking(let verify, let verifyActive, let verifyDuration, _, _) = steps[3],
              case .webSearches(let c) = steps[4] else {
            Issue.record("Unexpected step shape: \(steps)")
            return
        }
        #expect(a.map(\.id) == ["first"])
        #expect(compare == "Compare")
        #expect(compareActive == false)
        #expect(compareDuration == 3)
        #expect(b.map(\.id) == ["second"])
        #expect(verify == "Verify")
        #expect(verifyActive == true)
        #expect(verifyDuration == nil)
        #expect(c.map(\.id) == ["third"])
    }

    @Test func adjacentSearchesStayMergedInsideAWorkRun() {
        let result = runs([
            .thinking(content: "Plan", isThinking: false, duration: 1),
            .webSearch(searchId: "first"),
            .webSearch(searchId: "second"),
            .urlFetch(fetchId: "page"),
        ])
        guard let steps = workSteps(result.first) else {
            Issue.record("Expected a work run, got \(result.map(\.id))")
            return
        }
        #expect(steps.count == 3)
        guard case .webSearches(let searches) = steps[1],
              case .urlFetches(let fetches) = steps[2] else {
            Issue.record("Unexpected step shape: \(steps)")
            return
        }
        #expect(searches.map(\.id) == ["first", "second"])
        #expect(fetches.map(\.id) == ["page"])
    }

    @Test func visibleTextAndWidgetsSeparateWorkRuns() {
        let boundaries: [MessageSegment] = [.text("Interim answer"), .toolCall(toolCallId: "widget")]
        for boundary in boundaries {
            let result = runs([.webSearch(searchId: "first"), boundary, .webSearch(searchId: "second")])
            let sizes = result.compactMap { run -> Int? in
                guard case .webSearches(let group) = run.run else { return nil }
                return group.count
            }
            #expect(sizes == [1, 1])
            #expect(!result.contains { if case .work = $0.run { return true }; return false })
        }
    }

    @Test func loneTraceRowsRenderAsThemselves() {
        let thinking = runs([.thinking(content: "Plan", isThinking: false, duration: 2), .text("Answer")])
        guard case .thinking(let content, let isThinking, let duration) = thinking.first?.run else {
            Issue.record("Expected a plain thinking row, got \(thinking.map(\.id))")
            return
        }
        #expect(content == "Plan")
        #expect(isThinking == false)
        #expect(duration == 2)
        #expect(thinking.first?.id == "thinking:0")

        let fetch = runs([.text("Intro"), .urlFetch(fetchId: "page")])
        guard case .urlFetches(let group) = fetch.last?.run else {
            Issue.record("Expected a plain fetch row, got \(fetch.map(\.id))")
            return
        }
        #expect(group.map(\.id) == ["page"])
        #expect(fetch.last?.id == "urlfetches:1:page")
    }

    @Test func closedEmptyThoughtDoesNotSplitOrCountAsAStep() {
        let result = runs([
            .webSearch(searchId: "first"),
            .thinking(content: "   ", isThinking: false, duration: nil),
            .webSearch(searchId: "second"),
        ])
        #expect(result.count == 1)
        guard case .webSearches(let group) = result.first?.run else {
            Issue.record("Expected the searches to merge into one row, got \(result.map(\.id))")
            return
        }
        #expect(group.map(\.id) == ["first", "second"])
    }

    @Test func openEmptyThoughtStillCountsAsAStep() {
        let result = runs([
            .webSearch(searchId: "first"),
            .thinking(content: "", isThinking: true, duration: nil),
        ])
        let steps = workSteps(result.first)
        #expect(steps?.count == 2)
        #expect(steps?.last?.isInFlight == true)
    }

    @Test func growingSearchGroupKeepsItsIdentity() {
        let first = runs([.webSearch(searchId: "first")])
        let expanded = runs([.webSearch(searchId: "first"), .webSearch(searchId: "second")])
        #expect(first.first?.id == expanded.first?.id)
    }

    @Test func workRunKeepsItsIdentityAsStepsArrive() {
        let first = runs([.thinking(content: "Plan", isThinking: false, duration: 1), .webSearch(searchId: "first")])
        let expanded = runs([
            .thinking(content: "Plan", isThinking: false, duration: 1),
            .webSearch(searchId: "first"),
            .urlFetch(fetchId: "page"),
        ])
        #expect(first.first?.id == "work:0:thinking")
        #expect(first.first?.id == expanded.first?.id)
    }
}
