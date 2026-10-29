import Testing
@testable import TinfoilChat

struct WorkRunTests {
    private func search(
        _ id: String,
        status: WebSearchStatus = .completed,
        query: String? = nil,
        startedAt: Double? = nil,
        endedAt: Double? = nil
    ) -> WebSearchInstance {
        WebSearchInstance(
            id: id,
            query: query,
            status: status,
            sources: [],
            reason: nil,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func thought(duration: Double? = 1) -> WorkStep {
        .thinking(content: "t", isThinking: false, duration: duration, startedAt: nil, endedAt: nil)
    }

    private func fetches(_ statuses: [URLFetchStatus]) -> WorkStep {
        .urlFetches(statuses.enumerated().map { URLFetchState(id: "f\($0.offset)", url: "https://x/\($0.offset)", status: $0.element) })
    }

    @Test func summaryNamesEachActionOnceInTheOrderFirstTaken() {
        let run = WorkRun(steps: [
            thought(),
            .webSearches([search("a")]),
            thought(),
            fetches([.completed, .completed]),
            .webSearches([search("b")]),
            fetches([.completed]),
        ])
        #expect(run.summaryLabel == "Thought, searched the web, and read 3 pages")
    }

    @Test func summaryJoinsTwoActionsWithoutAComma() {
        let run = WorkRun(steps: [.webSearches([search("a")]), fetches([.completed])])
        #expect(run.summaryLabel == "Searched the web and read a page")

        let thinking = WorkRun(steps: [thought(), .webSearches([search("a")]), thought()])
        #expect(thinking.summaryLabel == "Thought and searched the web")
    }

    @Test func summaryCountsOnlyThePagesRead() {
        let someFailed = WorkRun(steps: [thought(), fetches([.completed, .failed, .blocked])])
        #expect(someFailed.summaryLabel == "Thought and read a page")

        let allFailed = WorkRun(steps: [thought(), fetches([.failed, .failed])])
        #expect(allFailed.summaryLabel == "Thought and tried to read 2 pages")
    }

    @Test func formatsWholeSecondsMinutesAndHours() {
        #expect(ElapsedTime.label(0) == "0s")
        #expect(ElapsedTime.label(8.9) == "8s")
        #expect(ElapsedTime.label(59.99) == "59s")
        #expect(ElapsedTime.label(60) == "1m 0s")
        #expect(ElapsedTime.label(213) == "3m 33s")
        #expect(ElapsedTime.label(3_599) == "59m 59s")
        #expect(ElapsedTime.label(3_840) == "1h 4m")
    }

    @Test func clampsElapsedTimeAtZero() {
        #expect(ElapsedTime.label(-4) == "0s")
        #expect(ElapsedTime.label(.nan) == "0s")
    }

    @Test func thoughtSaysItsDurationInTheSameFormat() {
        #expect(WorkStep.thoughtLabel(duration: 12.7) == "Thought for 12s")
        #expect(WorkStep.thoughtLabel(duration: 213) == "Thought for 3m 33s")
        #expect(WorkStep.thoughtLabel(duration: nil) == "Thought")
    }

    @Test func liveActivityFollowsTheLastInFlightStep() {
        let thinking = WorkRun(steps: [
            .webSearches([search("a")]),
            .thinking(content: "", isThinking: true, duration: nil, startedAt: nil, endedAt: nil),
        ])
        #expect(thinking.liveActivity == .thinking)

        let searching = WorkRun(steps: [
            .thinking(content: "t", isThinking: false, duration: 1, startedAt: nil, endedAt: nil),
            .webSearches([search("a"), search("b", status: .searching, query: "latest news")]),
        ])
        #expect(searching.liveActivity == .searching(query: "latest news"))

        let reading = WorkRun(steps: [
            .webSearches([search("a")]),
            .urlFetches([
                URLFetchState(id: "f1", url: "https://a", status: .completed),
                URLFetchState(id: "f2", url: "https://b", status: .fetching),
            ]),
        ])
        #expect(reading.liveActivity == .reading(count: 2))

        let settled = WorkRun(steps: [
            .thinking(content: "t", isThinking: false, duration: 1, startedAt: nil, endedAt: nil),
            .webSearches([search("a")]),
        ])
        #expect(settled.liveActivity == .idle)
    }
}
