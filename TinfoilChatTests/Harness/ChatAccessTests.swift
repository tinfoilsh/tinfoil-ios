import Foundation
import Testing
@testable import TinfoilChat

/// A control plane that answers each path from a script, in order.
private actor ScriptedControlPlane: ControlPlaneTransport {
    struct Call: Equatable { let path: String; let identity: String? }
    private(set) var calls: [Call] = []
    private var answers: [ControlPlaneAnswer]

    init(_ answers: [ControlPlaneAnswer]) {
        self.answers = answers
    }

    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer {
        calls.append(Call(path: path, identity: identity))
        guard !answers.isEmpty else {
            Issue.record("unscripted control plane request to \(path)")
            throw HarnessError(code: HarnessErrorCode.connection, message: "unscripted", action: .stop)
        }
        return answers.removeFirst()
    }
}

private func answer(_ status: Int, _ json: String, headers: [String: String] = [:]) -> ControlPlaneAnswer {
    ControlPlaneAnswer(status: status, headers: headers, body: Data(json.utf8))
}

private final class Reported: @unchecked Sendable {
    var limits: [HarnessRateLimit] = []
}

/// A clock a test moves.
private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@Suite("Chat access")
struct ChatAccessTests {
    private let now = ChatAccessCache.date(of: "2027-01-15T00:00:00Z")!
    private let inAnHour = "2027-01-15T01:00:00Z"

    private func cache(_ controlPlane: ScriptedControlPlane, reported: Reported = Reported(), clock: Clock? = nil) -> ChatAccessCache {
        let clock = clock ?? Clock(now)
        return ChatAccessCache(controlPlane: controlPlane, onRateLimit: { reported.limits.append($0) }, now: { clock.now })
    }

    @Test func aSubscribersTokenIsMintedOnceAndReportsItsQuota() async throws {
        let plane = ScriptedControlPlane([
            answer(200, #"{"key":"tok_1","expires_at":"\#(inAnHour)","rate_limit":{"max_input_tokens":1000,"input_tokens_used":10,"input_tokens_remaining":990}}"#),
        ])
        let reported = Reported()
        let access = cache(plane, reported: reported)
        #expect(try await access.get(identity: "jwt") == "tok_1")
        #expect(try await access.get(identity: "jwt") == "tok_1")
        #expect(await plane.calls == [.init(path: Constants.API.SessionToken.chatPath, identity: "jwt")])
        #expect(reported.limits.first?.kind?.value1 == .hourly)
        #expect(reported.limits.first?.inputTokens?.remaining == 990)
        let renewal = try #require(await access.renewsAt())
        #expect(renewal == ChatAccessCache.date(of: inAnHour)!.addingTimeInterval(-Constants.Harness.ChatAccess.renewBeforeExpirySeconds))
    }

    @Test func anAccountWithoutASubscriptionFallsBackToItsFreeKey() async throws {
        let plane = ScriptedControlPlane([
            answer(402, #"{"error":"subscription required"}"#),
            answer(200, #"{"key":"free_1","is_free_tier":true,"expires_at":"\#(inAnHour)","rate_limit":{"max_requests":20,"remaining":19}}"#),
        ])
        let reported = Reported()
        let access = cache(plane, reported: reported)
        #expect(try await access.get(identity: "jwt") == "free_1")
        #expect(await plane.calls.map(\.path) == [Constants.API.SessionToken.chatPath, Constants.Harness.ChatAccess.freeKeyPath])
        #expect(reported.limits.first?.kind?.value1 == .freeDaily)
        #expect(reported.limits.first?.remaining == 19)
        // A free key renews with the request that needs it, not ahead.
        #expect(await access.renewsAt() == nil)
    }

    @Test func anHourlyCapIsKeptUntilItResets() async throws {
        let resets = "2027-01-15T00:30:00Z"
        let plane = ScriptedControlPlane([
            answer(429, #"{"code":"HOURLY_LIMIT_REACHED","error":"Hourly limit reached","resets_at":"\#(resets)"}"#),
            answer(200, #"{"key":"tok_2","expires_at":"\#(inAnHour)"}"#),
        ])
        let reported = Reported()
        let clock = Clock(now)
        let access = cache(plane, reported: reported, clock: clock)
        let first = await failure { try await access.get(identity: "jwt") }
        #expect(first?.code == HarnessErrorCode.quotaExhausted)
        #expect(first?.action == .wait)
        #expect(first?.detail.kind == "hourly")
        #expect(first?.detail.resetsAt == resets)
        #expect(reported.limits.first?.remaining == 0)
        // The refusal answers again without asking the control plane, and
        // names when it lifts.
        let second = await failure { try await access.get(identity: "jwt") }
        #expect(second == first)
        #expect(await plane.calls.count == 1)
        #expect(await access.renewsAt() == ChatAccessCache.date(of: resets))
        // Once it lifts, the control plane is asked again.
        clock.now = ChatAccessCache.date(of: resets)!.addingTimeInterval(1)
        #expect(try await access.get(identity: "jwt") == "tok_2")
        #expect(await plane.calls.count == 2)
    }

    @Test func aTransientFailureKeepsTheTokenHeld() async throws {
        let plane = ScriptedControlPlane([
            answer(200, #"{"key":"tok_1","expires_at":"\#(inAnHour)"}"#),
            answer(503, #"{"error":"busy"}"#),
            answer(200, #"{"key":"tok_2","expires_at":"\#(inAnHour)"}"#),
        ])
        let access = cache(plane)
        #expect(try await access.get(identity: "jwt") == "tok_1")
        // Refreshing asks again; the busy answer is refused to the caller
        // that refreshed but leaves the token for everyone else.
        let refused = await failure { try await access.get(identity: "jwt", refresh: true) }
        #expect(refused?.code == HarnessErrorCode.upstreamRefused)
        #expect(refused?.action == .retry)
        #expect(try await access.get(identity: "jwt") == "tok_1")
        await access.reset()
        #expect(try await access.get(identity: "jwt") == "tok_2")
    }

    @Test func aSignedOutCallersFreeKeyIsCheckedAndKept() async throws {
        let plane = ScriptedControlPlane([
            answer(200, #"{"key":"paid_1","is_free_tier":false,"expires_at":"\#(inAnHour)"}"#),
            answer(200, #"{"key":"free_2","is_free_tier":true,"expires_at":"\#(inAnHour)"}"#),
        ])
        let anonymous = AnonymousAccessCache(controlPlane: plane, now: { now })
        let refused = await failure { try await anonymous.get() }
        #expect(refused?.code == HarnessErrorCode.upstreamRefused)
        #expect(try await anonymous.get() == "free_2")
        #expect(try await anonymous.get() == "free_2")
        #expect(await plane.calls.count == 2)
        #expect(await plane.calls.allSatisfy { $0.identity == nil })
    }

    private func failure(_ body: () async throws -> Void) async -> HarnessError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? HarnessError
        }
    }
}
