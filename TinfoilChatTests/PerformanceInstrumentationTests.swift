import Foundation
import Testing
@testable import TinfoilChat

@Suite("Performance instrumentation")
struct PerformanceInstrumentationTests {
    @Test("pairs begin and end events")
    func pairsBeginAndEnd() {
        let sink = RecordingPerformanceSink()
        let instrumentation = PerformanceInstrumentation(sink: sink)

        let token = instrumentation.begin(.chatIndexLoad)
        instrumentation.end(token)

        #expect(sink.recordedEvents == [
            .begin(token),
            .end(token),
        ])
    }

    @Test("creates distinct interval tokens")
    func createsDistinctTokens() {
        let sink = RecordingPerformanceSink()
        let instrumentation = PerformanceInstrumentation(sink: sink)

        let first = instrumentation.begin(.fullChatLoad)
        let second = instrumentation.begin(.fullChatLoad)
        instrumentation.end(first)
        instrumentation.end(second)

        #expect(first != second)
        #expect(sink.recordedEvents == [
            .begin(first),
            .begin(second),
            .end(first),
            .end(second),
        ])
    }

    @Test("ends measured intervals when the operation throws")
    func endsThrownOperation() {
        let sink = RecordingPerformanceSink()
        let instrumentation = PerformanceInstrumentation(sink: sink)

        do {
            try instrumentation.measure(.remoteConfigLoad) {
                throw TestError.expected
            }
            Issue.record("Expected the measured operation to throw")
        } catch TestError.expected {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let events = sink.recordedEvents
        #expect(events.count == 2)
        guard events.count == 2 else { return }
        guard case .begin(let beginToken) = events[0],
              case .end(let endToken) = events[1] else {
            Issue.record("Expected one begin event followed by one end event")
            return
        }
        #expect(beginToken == endToken)
    }

    @Test("exposes only fixed phase names")
    func exposesFixedPhaseNames() {
        let expectedNames: Set<String> = [
            "remoteConfigLoad",
            "chatIndexLoad",
            "fullChatLoad",
            "cloudSyncCycle",
            "firstChatPageLoad",
            "streamSnapshotBuild",
            "selectedChatImageHydration",
        ]

        #expect(Set(PerformancePhase.allCases.map(\.rawValue)) == expectedNames)
    }

    @Test("does not record disabled intervals")
    func skipsDisabledIntervals() {
        let sink = RecordingPerformanceSink(isEnabled: false)
        let instrumentation = PerformanceInstrumentation(sink: sink)

        let token = instrumentation.begin(.streamSnapshotBuild)
        instrumentation.end(token)

        #expect(sink.recordedEvents.isEmpty)
    }

    @Test("ends measured intervals when the operation is cancelled")
    func endsCancelledOperation() async {
        let sink = RecordingPerformanceSink()
        let instrumentation = PerformanceInstrumentation(sink: sink)
        let task = Task {
            let token = instrumentation.begin(.fullChatLoad)
            defer { instrumentation.end(token) }
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }

        while sink.recordedEvents.isEmpty {
            await Task.yield()
        }
        task.cancel()
        _ = try? await task.value

        let events = sink.recordedEvents
        #expect(events.count == 2)
        guard events.count == 2,
              case .begin(let beginToken) = events[0],
              case .end(let endToken) = events[1] else {
            Issue.record("Expected one begin event followed by one end event")
            return
        }
        #expect(beginToken == endToken)
    }
}

private enum TestError: Error {
    case expected
}

private final class RecordingPerformanceSink: PerformanceInstrumentationSink, @unchecked Sendable {
    enum Event: Equatable {
        case begin(PerformanceIntervalToken)
        case end(PerformanceIntervalToken)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    var recordedEvents: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func begin(_ token: PerformanceIntervalToken) {
        lock.lock()
        events.append(.begin(token))
        lock.unlock()
    }

    func end(_ token: PerformanceIntervalToken) {
        lock.lock()
        events.append(.end(token))
        lock.unlock()
    }
}
