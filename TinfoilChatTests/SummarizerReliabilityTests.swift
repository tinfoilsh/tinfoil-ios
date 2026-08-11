import Foundation
import Testing
@testable import TinfoilChat

private actor SummaryProbe {
    private var requests: [String] = []
    private var continuations: [CheckedContinuation<String, Error>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func summarize(_ content: String) async throws -> String {
        requests.append(content)
        let ready = countWaiters.filter { requests.count >= $0.0 }
        countWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func succeedNext(with summary: String) {
        continuations.removeFirst().resume(returning: summary)
    }

    func failNext() {
        continuations.removeFirst().resume(throwing: URLError(.timedOut))
    }

    func snapshot() -> [String] { requests }
}

struct SummarizerReliabilityTests {
    @Test func parsesStructuredErrorsWithoutSurfacingServerProse() {
        let body = Data(#"{"code":"OVERLOADED","error":"internal detail"}"#.utf8)
        let error = SummarizerService.parseError(statusCode: 503, body: body)

        #expect(error == .requestFailed(statusCode: 503, code: "OVERLOADED"))
        #expect(error.localizedDescription.contains("internal detail") == false)
    }

    @Test func breakerAllowsOnlyOneHalfOpenProbe() async throws {
        let coordinator = SummarizerRequestCoordinator(
            maximumConcurrentRequests: 2,
            breakerDelays: [15, 30, 60, 120],
            maximumBreakerDelay: 300
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let permit = try await coordinator.acquire(now: start)
        await coordinator.finish(permit, error: URLError(.timedOut), now: start)

        do {
            _ = try await coordinator.acquire(now: start.addingTimeInterval(14))
            Issue.record("Expected the breaker to remain open")
        } catch SummarizerError.temporarilyUnavailable {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        _ = try await coordinator.acquire(now: start.addingTimeInterval(15))
        do {
            _ = try await coordinator.acquire(now: start.addingTimeInterval(15))
            Issue.record("Expected a single half-open probe")
        } catch SummarizerError.temporarilyUnavailable {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func thoughtsUseLatestSnapshotAndRetainSuccessfulSummaryOnFailure() async {
        let probe = SummaryProbe()
        let service = ThinkingSummaryService(cooldownSeconds: 0) { content in
            try await probe.summarize(content)
        }
        var received: [String] = []
        let first = String(repeating: "a", count: 120)
        let latest = String(repeating: "b", count: 160)

        service.generateSummary(thoughts: first) { received.append($0) }
        await probe.waitForRequestCount(1)
        service.generateSummary(thoughts: latest) { received.append($0) }
        await probe.succeedNext(with: "first summary")
        await probe.waitForRequestCount(2)

        let requests = await probe.snapshot()
        #expect(requests == [first, latest])
        #expect(service.summary == "first summary")
        await probe.failNext()
        let newest = String(repeating: "d", count: 200)
        service.generateSummary(thoughts: newest) { received.append($0) }
        await probe.waitForRequestCount(3)
        #expect(service.summary == "first summary")
        #expect(received == ["first summary"])
        await probe.failNext()
    }

    @Test @MainActor
    func failedThoughtAttemptDoesNotAdvanceContentLength() async {
        let probe = SummaryProbe()
        let service = ThinkingSummaryService(cooldownSeconds: 0) { content in
            try await probe.summarize(content)
        }
        let thoughts = String(repeating: "c", count: 120)

        service.generateSummary(thoughts: thoughts) { _ in }
        await probe.waitForRequestCount(1)
        await probe.failNext()
        service.generateSummary(thoughts: thoughts) { _ in }
        await probe.waitForRequestCount(2)

        let requests = await probe.snapshot()
        #expect(requests == [thoughts, thoughts])
        await probe.failNext()
    }
}
