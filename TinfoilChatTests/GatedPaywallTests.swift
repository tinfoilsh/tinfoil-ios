import Testing
@testable import TinfoilChat

@Suite("Gated paywall")
struct GatedPaywallTests {
    @Test("dismissal requires current active subscription metadata")
    func currentActiveSubscription() {
        #expect(shouldDismissGatedPaywall(subscriptionRefreshSucceeded: true, hasActiveSubscription: true))
        #expect(!shouldDismissGatedPaywall(subscriptionRefreshSucceeded: false, hasActiveSubscription: true))
        #expect(!shouldDismissGatedPaywall(subscriptionRefreshSucceeded: true, hasActiveSubscription: false))
    }
}
