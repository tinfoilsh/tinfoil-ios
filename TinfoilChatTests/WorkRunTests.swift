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

    @Test func durationSpansTheRunRatherThanSummingOverlappingSteps() {
        let run = WorkRun(steps: [
            .thinking(content: "t", isThinking: false, duration: 4, startedAt: 1_000, endedAt: 5_000),
            .webSearches([
                search("a", startedAt: 5_000, endedAt: 20_000),
                search("b", startedAt: 5_000, endedAt: 25_000),
            ]),
        ])
        #expect(run.durationSeconds == 24)
    }

    @Test func unsettledStepUsesItsStart() {
        let run = WorkRun(steps: [
            .webSearches([search("a", startedAt: 0, endedAt: 3_000)]),
            .urlFetches([URLFetchState(id: "f", url: "https://x", status: .fetching, startedAt: 4_000)]),
        ])
        #expect(run.durationSeconds == 4)
    }

    @Test func fallsBackToSummedThinkingDurationsWithoutStamps() {
        let run = WorkRun(steps: [
            .thinking(content: "a", isThinking: false, duration: 4.7, startedAt: nil, endedAt: nil),
            .webSearches([search("a")]),
            .thinking(content: "b", isThinking: false, duration: 10.3, startedAt: nil, endedAt: nil),
        ])
        #expect(run.durationSeconds == 15)
        #expect(run.summaryLabel == "Worked for 15.0s")
    }

    @Test func describesStepCountWhenNothingCarriesTiming() {
        let run = WorkRun(steps: [
            .thinking(content: "a", isThinking: false, duration: nil, startedAt: nil, endedAt: nil),
            .webSearches([search("a")]),
        ])
        #expect(run.durationSeconds == nil)
        #expect(run.summaryLabel == "Worked through 2 steps")
    }

    @Test func formatsSecondsThenMinutes() {
        #expect(WorkRun.formatDuration(4.74) == "4.7s")
        #expect(WorkRun.formatDuration(59.96) == "1m 0s")
        #expect(WorkRun.formatDuration(84.2) == "1m 24s")
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
