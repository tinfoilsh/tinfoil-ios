import Testing
@testable import TinfoilChat

struct WorkRunTests {
    private func search(
        _ id: String,
        status: WebSearchStatus = .completed,
        query: String? = nil,
        startedAt: Double? = nil
    ) -> WebSearchInstance {
        WebSearchInstance(
            id: id,
            query: query,
            status: status,
            sources: [],
            reason: nil,
            startedAt: startedAt
        )
    }

    private func thought(duration: Double? = 1) -> WorkStep {
        .thinking(content: "t", isThinking: false, duration: duration, startedAt: nil)
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
        #expect(run.summaryLabel == "Thought, searched the web, and read 3 links")
    }

    @Test func summaryJoinsTwoActionsWithoutAComma() {
        let run = WorkRun(steps: [.webSearches([search("a")]), fetches([.completed])])
        #expect(run.summaryLabel == "Searched the web and read a link")

        let thinking = WorkRun(steps: [thought(), .webSearches([search("a")]), thought()])
        #expect(thinking.summaryLabel == "Thought and searched the web")
    }

    @Test func summaryCountsOnlyThePagesRead() {
        let someFailed = WorkRun(steps: [thought(), fetches([.completed, .failed, .blocked])])
        #expect(someFailed.summaryLabel == "Thought and read a link")

        let allFailed = WorkRun(steps: [thought(), fetches([.failed, .failed])])
        #expect(allFailed.summaryLabel == "Thought and tried to read 2 links")
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
            .thinking(content: "", isThinking: true, duration: nil, startedAt: nil),
        ])
        #expect(thinking.liveActivity == .thinking)

        let searching = WorkRun(steps: [
            .thinking(content: "t", isThinking: false, duration: 1, startedAt: nil),
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
            .thinking(content: "t", isThinking: false, duration: 1, startedAt: nil),
            .webSearches([search("a")]),
        ])
        #expect(settled.liveActivity == .idle)
    }

    @Test func runHeaderSaysWhatItDoesWhileLiveAndWhatItDidOnceSettled() {
        let thinking = WorkRun(steps: [
            .webSearches([search("a")]),
            .thinking(content: "", isThinking: true, duration: nil, startedAt: nil),
        ])
        #expect(thinking.label(isActive: true) == WorkLabel(text: "Thinking", tone: .live, shimmers: true))
        #expect(thinking.label(isActive: true, thinkingSummary: "Comparing sources").text == "Comparing sources")

        let settled = WorkRun(steps: [thought(), .webSearches([search("a")])])
        #expect(settled.label(isActive: true) == WorkLabel(text: "Working", tone: .live, shimmers: true))
        #expect(settled.label(isActive: false) == WorkLabel(text: "Thought and searched the web", tone: .settled))
    }

    @Test func stepHeaderSaysHowItEnded() {
        #expect(thought(duration: 12.4).label(isActive: false) == WorkLabel(text: "Thought for 12s", tone: .settled))
        #expect(WorkStep.webSearches([search("a"), search("b")]).label(isActive: false).text == "Searched the web on 2 queries")
        #expect(WorkStep.webSearches([search("a"), search("b", status: .failed)]).label(isActive: false) == WorkLabel(text: "Search failed", tone: .failed))
        #expect(fetches([.completed, .failed]).label(isActive: false).text == "Read 1 link")
        #expect(fetches([.failed, .blocked]).label(isActive: false).text == "Tried to read 2 links")

        let searching = WorkStep.webSearches([search("a", status: .searching, query: "tides")])
        #expect(searching.label(isActive: true) == WorkLabel(text: "Searching the web: tides", tone: .live))
    }

    @Test func runCountsFromItsEarliestStamp() {
        let run = WorkRun(steps: [
            .thinking(content: "t", isThinking: false, duration: 1, startedAt: 5_000),
            .webSearches([search("a", startedAt: 9_000), search("b", startedAt: 2_000)]),
            .urlFetches([URLFetchState(id: "f", url: "https://x", status: .fetching)]),
        ])
        #expect(run.startedAt == 2_000)
        #expect(run.steps[1].startedAt == 2_000)
        #expect(run.steps[2].startedAt == nil)
    }

    @Test func stepsOfOneKindOpenSeparately() {
        let run = WorkRun(steps: [thought(), .webSearches([search("a")]), thought()])
        let rowIds = run.steps.enumerated().map { WorkRun.stepRowId($0.element, at: $0.offset, in: "work:0") }
        #expect(Set(rowIds).count == run.steps.count)

        let expansion = WorkStepExpansion()
        expansion.toggle(rowIds[2])
        #expect(expansion.isExpanded(rowIds[2]))
        #expect(!expansion.isExpanded(rowIds[0]))
        #expect(!expansion.isExpanded("work:0"))
        expansion.toggle(rowIds[2])
        #expect(!expansion.isExpanded(rowIds[2]))
    }

    @Test func aLoneStepOpensAsTheFirstStepOfTheRunItGrowsInto() {
        let step = thought()
        let run = WorkRun(steps: [step, .webSearches([search("a")])])
        let expansion = WorkStepExpansion()

        expansion.toggleLoneStep(step, rowId: "work:0:thinking")
        #expect(expansion.isExpanded("work:0:thinking"))
        #expect(expansion.isExpanded(WorkRun.stepRowId(run.steps[0], at: 0, in: "work:0:thinking")))
        #expect(!expansion.isExpanded(WorkRun.stepRowId(run.steps[1], at: 1, in: "work:0:thinking")))

        expansion.toggleLoneStep(step, rowId: "work:0:thinking")
        #expect(expansion.expandedRows.isEmpty)
    }
}
