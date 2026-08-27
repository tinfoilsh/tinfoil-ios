import Foundation
import Testing
@testable import TinfoilChat

@Suite("Subscription access policy")
struct SubscriptionAccessPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("allows eligible statuses without an expiration", arguments: ["active", "trialing", "canceled"])
    func eligibleStatusWithoutExpiration(status: String) {
        #expect(SubscriptionAccessPolicy.isActive(status: status, expiresAt: nil, now: now))
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

    @Test("refreshes credentials only when access changes")
    func credentialRefreshTransition() {
        #expect(SubscriptionAccessPolicy.requiresCredentialRefresh(previous: false, current: true))
        #expect(SubscriptionAccessPolicy.requiresCredentialRefresh(previous: true, current: false))
        #expect(!SubscriptionAccessPolicy.requiresCredentialRefresh(previous: false, current: false))
        #expect(!SubscriptionAccessPolicy.requiresCredentialRefresh(previous: true, current: true))
    }
}
