import Testing
@testable import TinfoilChat

@Suite("Start fresh confirmation")
struct StartFreshConfirmationTests {
    @Test func cancellationDoesNotAuthorizeAction() {
        var confirmation = StartFreshConfirmationState()
        var actionCount = 0
        confirmation.request()

        confirmation.cancel()
        confirmation.confirm { actionCount += 1 }

        #expect(!confirmation.isPresented)
        #expect(actionCount == 0)
    }

    @Test func confirmationAuthorizesActionExactlyOnce() {
        var confirmation = StartFreshConfirmationState()
        var actionCount = 0
        confirmation.request()

        confirmation.dismissPresentation()
        confirmation.confirm { actionCount += 1 }
        confirmation.confirm { actionCount += 1 }

        #expect(!confirmation.isPresented)
        #expect(actionCount == 1)
    }
}
