import Testing
@testable import TinfoilChat

struct AccountActionReadinessTests {
    @Test func signedInActionsWaitForTheCurrentAccountToFinishLoading() {
        #expect(!AccountActionReadiness.canPerform(isAuthenticated: true, userId: "current", readyUserId: nil))
        #expect(!AccountActionReadiness.canPerform(isAuthenticated: true, userId: nil, readyUserId: nil))
        #expect(!AccountActionReadiness.canPerform(isAuthenticated: true, userId: "current", readyUserId: "previous"))
        #expect(AccountActionReadiness.canPerform(isAuthenticated: true, userId: "current", readyUserId: "current"))
    }

    @Test func signedOutActionsDoNotRequireAccountStartup() {
        #expect(AccountActionReadiness.canPerform(isAuthenticated: false, userId: nil, readyUserId: nil))
    }
}
