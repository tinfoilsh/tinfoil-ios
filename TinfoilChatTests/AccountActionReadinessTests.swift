import Testing
@testable import TinfoilChat

struct AccountActionReadinessTests {
    @Test func signedInActionsWaitForTheCurrentAccountToFinishLoading() {
        #expect(!AccountActionReadiness.canPerform(isTearingDown: false, isAuthenticated: true, userId: "current", readyUserId: nil))
        #expect(!AccountActionReadiness.canPerform(isTearingDown: false, isAuthenticated: true, userId: nil, readyUserId: nil))
        #expect(!AccountActionReadiness.canPerform(isTearingDown: false, isAuthenticated: true, userId: "current", readyUserId: "previous"))
        #expect(AccountActionReadiness.canPerform(isTearingDown: false, isAuthenticated: true, userId: "current", readyUserId: "current"))
    }

    @Test func signedOutActionsDoNotRequireAccountStartup() {
        #expect(AccountActionReadiness.canPerform(isTearingDown: false, isAuthenticated: false, userId: nil, readyUserId: nil))
    }

    @Test func accountTeardownBlocksActionsUntilCleanupFinishes() {
        #expect(!AccountActionReadiness.canPerform(isTearingDown: true, isAuthenticated: true, userId: "current", readyUserId: "current"))
        #expect(!AccountActionReadiness.canPerform(isTearingDown: true, isAuthenticated: false, userId: nil, readyUserId: nil))
        #expect(AccountActionReadiness.canPerform(isTearingDown: false, isAuthenticated: false, userId: nil, readyUserId: nil))
    }
}
