import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct ChatTokenRequestGateTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-09-26T10:58:00Z")!
    private static let reset = "2026-09-26T11:00:00Z"
    private static let resetDate = ISO8601DateFormatter().date(from: reset)!
    private static let bearer = "account-a"
    private static let key = "subscriber-token"

    private static func response(
        status: Int = 200,
        body: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: URL(string: Constants.API.baseURL + Constants.API.SessionToken.chatPath)!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
        return (try JSONSerialization.data(withJSONObject: body ?? ["key": key]), response)
    }

    private static func limitedResponse() throws -> (Data, URLResponse) {
        try response(status: 429, body: [
            "code": Constants.API.ErrorCode.hourlyLimitReached,
            "resets_at": reset,
        ])
    }

    @Test(arguments: [false, true])
    func concurrentCallersShareOneImmediateRequest(rateLimited: Bool) async throws {
        let started = Signal()
        let release = Signal()
        let entered = Signal(target: 3)
        var requests: [URLRequest] = []
        let gate = ChatTokenRequestGate(send: { request in
            requests.append(request)
            started.signal()
            await release.wait()
            return rateLimited ? try Self.limitedResponse() : try Self.response()
        }, now: { Self.start })
        defer { gate.reset() }
        let callers = (0..<3).map { _ in
            Task { @MainActor in
                entered.signal()
                return await gate.fetch(jwt: Self.bearer)
            }
        }
        await entered.wait()
        await started.wait()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == Constants.API.SessionToken.chatPath)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.bearer)")
        release.signal()
        let expected: ChatTokenRequestGate.Result = rateLimited
            ? .rateLimited(resetsAt: Self.reset, retryAt: Self.resetDate)
            : .token(key: Self.key, expiresAt: nil)
        for caller in callers {
            #expect(await caller.value == expected)
        }
        #expect(requests.count == 1)
    }

    @Test
    func repeatedPollsReturnTheCachedLimitWithoutExtendingItsDeadline() async throws {
        var now = Self.start
        var calls = 0
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            return calls == 1 ? try Self.limitedResponse() : try Self.response()
        }, now: { now })
        defer { gate.reset() }
        let expected = ChatTokenRequestGate.Result.rateLimited(resetsAt: Self.reset, retryAt: Self.resetDate)
        #expect(await gate.fetch(jwt: Self.bearer) == expected)
        for _ in 0..<3 {
            now.addTimeInterval(30)
            #expect(await gate.fetch(jwt: Self.bearer) == expected)
            #expect(calls == 1)
        }
        now = Self.resetDate.addingTimeInterval(-1)
        #expect(gate.isCoolingDown)
        now = Self.resetDate
        #expect(await gate.fetch(jwt: Self.bearer) == .token(key: Self.key, expiresAt: nil))
        #expect(calls == 2)
        #expect(!gate.isCoolingDown)
    }

    @Test
    func resetMetadataAndRetryAfterDetermineABoundedCooldown() async throws {
        struct Scenario {
            var body: [String: Any] = [:]
            var headers: [String: String] = [:]
            let delay: TimeInterval
        }
        let scenarios = [
            Scenario(body: ["resets_at": Self.reset], delay: 120),
            Scenario(body: ["resets_at": "2026-09-26T11:00:00.000Z"], delay: 120),
            Scenario(body: ["rate_limit": ["resets_at": Self.reset]], delay: 120),
            Scenario(headers: ["Retry-After": "120"], delay: 120),
            Scenario(headers: ["Retry-After": "Sat, 26 Sep 2026 11:00:00 GMT"], delay: 120),
            Scenario(body: ["resets_at": "invalid"], headers: ["Retry-After": "120"], delay: 120),
            Scenario(body: ["resets_at": Self.reset], headers: ["Date": "Sat, 26 Sep 2026 10:59:00 GMT"], delay: 60),
            Scenario(delay: Constants.API.SessionToken.rateLimitFallbackSeconds),
            Scenario(headers: ["Retry-After": "-1"], delay: Constants.API.SessionToken.rateLimitFallbackSeconds),
            Scenario(headers: ["Retry-After": "invalid"], delay: Constants.API.SessionToken.rateLimitFallbackSeconds),
            Scenario(headers: ["Retry-After": "999999999"], delay: Constants.API.SessionToken.maximumCooldownSeconds),
            Scenario(body: ["resets_at": "2026-09-26T10:00:00Z"], delay: Constants.API.SessionToken.rateLimitFallbackSeconds),
        ]
        for scenario in scenarios {
            let gate = ChatTokenRequestGate(send: { _ in
                try Self.response(status: 429, body: scenario.body, headers: scenario.headers)
            }, now: { Self.start })
            defer { gate.reset() }
            let result = await gate.fetch(jwt: Self.bearer)
            guard case .rateLimited(_, let retryAt) = result else {
                Issue.record("Expected a rate limit, received \(result)")
                continue
            }
            #expect(retryAt == Self.start.addingTimeInterval(scenario.delay))
        }
    }

    @Test
    func automaticallyRechecksOnceAtTheReset() async throws {
        let sleeper = Sleeper()
        let refreshed = Signal()
        var now = Self.start
        var calls = 0
        var refreshResult: ChatTokenRequestGate.Result?
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            return calls == 1 ? try Self.limitedResponse() : try Self.response()
        }, now: { now }, sleep: { await sleeper.sleep($0) })
        defer { gate.reset() }
        gate.onCooldownExpired = { [weak gate] in
            refreshResult = await gate?.fetch(jwt: Self.bearer)
            refreshed.signal()
        }
        _ = await gate.fetch(jwt: Self.bearer)
        await sleeper.started.wait()
        #expect(sleeper.delay == 120)
        #expect(calls == 1)

        now = Self.resetDate
        sleeper.wake()
        await refreshed.wait()
        #expect(refreshResult == .token(key: Self.key, expiresAt: nil))
        #expect(calls == 2)
        #expect(!gate.isCoolingDown)
    }

    @Test
    func manualRecheckCanRecoverEarlyWithoutAnotherScheduledRefresh() async throws {
        let sleeper = Sleeper()
        var calls = 0
        var automaticRefreshes = 0
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            return calls == 1 ? try Self.limitedResponse() : try Self.response()
        }, now: { Self.start }, sleep: { await sleeper.sleep($0) })
        defer { gate.reset() }
        gate.onCooldownExpired = { automaticRefreshes += 1 }
        _ = await gate.fetch(jwt: Self.bearer)
        await sleeper.started.wait()

        #expect(await gate.fetch(jwt: Self.bearer, bypassCooldown: true) == .token(key: Self.key, expiresAt: nil))
        #expect(calls == 2)
        #expect(!gate.isCoolingDown)
        sleeper.wake()
        await sleeper.finished.wait()
        #expect(automaticRefreshes == 0)
    }

    @Test
    func failedEarlyRecheckPreservesTheKnownCapAndOriginalReset() async throws {
        var calls = 0
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            return calls == 1 ? try Self.limitedResponse() : try Self.response(status: 503, body: [:])
        }, now: { Self.start })
        defer { gate.reset() }
        let limited = await gate.fetch(jwt: Self.bearer)
        #expect(await gate.fetch(jwt: Self.bearer, bypassCooldown: true) == limited)
        #expect(await gate.fetch(jwt: Self.bearer) == limited)
        #expect(calls == 2)
        #expect(gate.isCoolingDown)
    }

    @Test
    func ordinaryFailuresAreNotCached() async throws {
        var calls = 0
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            return calls == 1 ? try Self.response(status: 503, body: [:]) : try Self.response()
        })
        defer { gate.reset() }
        #expect(await gate.fetch(jwt: Self.bearer) == .unavailable)
        #expect(await gate.fetch(jwt: Self.bearer) == .token(key: Self.key, expiresAt: nil))
        #expect(calls == 2)
    }

    @Test
    func invalidationClearsTheCooldownAndCancelsItsResetCallback() async throws {
        let sleeper = Sleeper()
        var calls = 0
        var automaticRefreshes = 0
        let gate = ChatTokenRequestGate(send: { request in
            calls += 1
            if calls == 1 { return try Self.limitedResponse() }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-b")
            return try Self.response()
        }, now: { Self.start }, sleep: { await sleeper.sleep($0) })
        gate.onCooldownExpired = { automaticRefreshes += 1 }
        _ = await gate.fetch(jwt: Self.bearer)
        await sleeper.started.wait()
        gate.reset()

        #expect(await gate.fetch(jwt: "account-b") == .token(key: Self.key, expiresAt: nil))
        sleeper.wake()
        await sleeper.finished.wait()
        #expect(automaticRefreshes == 0)
        #expect(calls == 2)
    }

    @Test
    func lateOldAccountResponseCannotApplyACooldownOrClearTheNewRequest() async throws {
        let oldStarted = Signal()
        let newStarted = Signal()
        let releaseOld = Signal()
        let releaseNew = Signal()
        let thirdEntered = Signal()
        var calls = 0
        let gate = ChatTokenRequestGate(send: { request in
            calls += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.bearer)" {
                oldStarted.signal()
                await releaseOld.wait()
                return try Self.limitedResponse()
            }
            newStarted.signal()
            await releaseNew.wait()
            return try Self.response()
        }, now: { Self.start })
        defer { gate.reset() }
        let oldCaller = Task { await gate.fetch(jwt: Self.bearer) }
        await oldStarted.wait()
        gate.reset()
        let newCaller = Task { await gate.fetch(jwt: "account-b") }
        await newStarted.wait()
        releaseOld.signal()
        #expect(await oldCaller.value == .cancelled)
        #expect(!gate.isCoolingDown)
        let thirdCaller = Task { @MainActor in
            thirdEntered.signal()
            return await gate.fetch(jwt: "account-b")
        }
        await thirdEntered.wait()
        releaseNew.signal()
        #expect(await newCaller.value == .token(key: Self.key, expiresAt: nil))
        #expect(await thirdCaller.value == .token(key: Self.key, expiresAt: nil))
        #expect(calls == 2)
    }

    @Test
    func cancellingOneWaiterDoesNotCancelTheSharedMint() async throws {
        let started = Signal()
        let release = Signal()
        let secondEntered = Signal()
        var calls = 0
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            started.signal()
            await release.wait()
            try Task.checkCancellation()
            return try Self.response()
        })
        defer { gate.reset() }
        let first = Task { await gate.fetch(jwt: Self.bearer) }
        await started.wait()
        let second = Task { @MainActor in
            secondEntered.signal()
            return await gate.fetch(jwt: Self.bearer)
        }
        await secondEntered.wait()
        first.cancel()
        release.signal()
        #expect(await first.value == .cancelled)
        #expect(await second.value == .token(key: Self.key, expiresAt: nil))
        #expect(calls == 1)
    }

    @Test
    func cancelledCallerDoesNotStartARequest() async throws {
        let release = Signal()
        var calls = 0
        let gate = ChatTokenRequestGate(send: { _ in
            calls += 1
            return try Self.response()
        })
        let caller = Task {
            await release.wait()
            return await gate.fetch(jwt: Self.bearer)
        }
        caller.cancel()
        release.signal()
        #expect(await caller.value == .cancelled)
        #expect(calls == 0)
    }

    @MainActor private final class Signal {
        private let target: Int
        private var count = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(target: Int = 1) { self.target = target }

        func signal() {
            count += 1
            guard count >= target else { return }
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            guard count < target else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @MainActor private final class Sleeper {
        let started = Signal()
        let finished = Signal()
        private let release = Signal()
        private(set) var delay: TimeInterval?

        func sleep(_ seconds: TimeInterval) async {
            delay = seconds
            started.signal()
            await release.wait()
            finished.signal()
        }

        func wake() { release.signal() }
    }
}
