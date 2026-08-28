import Foundation
import Testing
@testable import TinfoilChat

@Suite("Subscription access policy")
struct SubscriptionAccessPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("allows renewable statuses without an expiration", arguments: ["active", "trialing"])
    func eligibleStatusWithoutExpiration(status: String) {
        #expect(SubscriptionAccessPolicy.isActive(status: status, expiresAt: nil, now: now))
    }

    @Test("requires a future expiration for canceled status")
    func canceledStatusExpiration() {
        #expect(!SubscriptionAccessPolicy.isActive(status: "canceled", expiresAt: nil, now: now))
        #expect(SubscriptionAccessPolicy.isActive(
            status: "canceled",
            expiresAt: "2027-01-15T08:00:01Z",
            now: now
        ))
    }

    @Test("applies expiration to every eligible status", arguments: ["active", "trialing", "canceled"])
    func eligibleStatusExpiration(status: String) {
        #expect(SubscriptionAccessPolicy.isActive(
            status: status,
            expiresAt: "2027-01-15T08:00:01Z",
            now: now
        ))
        #expect(!SubscriptionAccessPolicy.isActive(
            status: status,
            expiresAt: "2027-01-15T07:59:59Z",
            now: now
        ))
    }

    @Test("rejects ineligible statuses", arguments: ["past_due", "expired", "paused", ""])
    func ineligibleStatus(status: String) {
        #expect(!SubscriptionAccessPolicy.isActive(status: status, expiresAt: nil, now: now))
    }

    @Test("rejects malformed expiration")
    func malformedExpiration() {
        #expect(!SubscriptionAccessPolicy.isActive(status: "active", expiresAt: "tomorrow", now: now))
    }

    @Test("missing status is inactive")
    func missingStatus() {
        #expect(!SubscriptionAccessPolicy.isActive(status: nil, expiresAt: nil, now: now))
    }

    @Test("schedules only future expirations")
    func scheduledExpiration() {
        let futureExpiration = Date(timeIntervalSince1970: 1_800_000_001)
        #expect(SubscriptionAccessPolicy.scheduledExpiration(
            status: "active",
            expiresAt: "2027-01-15T08:00:01Z",
            now: now
        ) == futureExpiration)
        #expect(SubscriptionAccessPolicy.scheduledExpiration(
            status: "active",
            expiresAt: "2027-01-15T07:59:59Z",
            now: now
        ) == nil)
        #expect(SubscriptionAccessPolicy.scheduledExpiration(
            status: "trialing",
            expiresAt: nil,
            now: now
        ) == nil)
        #expect(SubscriptionAccessPolicy.scheduledExpiration(
            status: nil,
            expiresAt: "2027-01-15T08:00:01Z",
            now: now
        ) == nil)
    }

    @Test("refreshes credentials only when access changes")
    func credentialRefreshTransition() {
        #expect(SubscriptionAccessPolicy.requiresCredentialRefresh(previous: false, current: true))
        #expect(SubscriptionAccessPolicy.requiresCredentialRefresh(previous: true, current: false))
        #expect(!SubscriptionAccessPolicy.requiresCredentialRefresh(previous: false, current: false))
        #expect(!SubscriptionAccessPolicy.requiresCredentialRefresh(previous: true, current: true))
    }

    @Test("rejects a delayed refresh after switching accounts")
    func delayedAccountSwitch() async {
        let refresh = SubscriptionRefreshContext(userId: "account-a", accountLifecycleGeneration: 4)

        await Task.yield()

        #expect(!refresh.isCurrent(userId: "account-b", accountLifecycleGeneration: 4))
        #expect(!refresh.isCurrent(userId: "account-a", accountLifecycleGeneration: 5))
    }

    @Test("rejects a delayed refresh after restarting the same account lifecycle")
    func delayedSameAccountLifecycleChange() async {
        let refresh = SubscriptionRefreshContext(userId: "account", accountLifecycleGeneration: 8)

        await Task.yield()

        #expect(!refresh.isCurrent(userId: "account", accountLifecycleGeneration: 9))
        #expect(refresh.isCurrent(userId: "account", accountLifecycleGeneration: 8))
    }
}
