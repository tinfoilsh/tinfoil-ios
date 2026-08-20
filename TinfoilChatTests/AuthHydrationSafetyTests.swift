import Testing
@testable import TinfoilChat

@Suite("Authentication hydration safety")
struct AuthHydrationSafetyTests {
    @Test("An expired session signs out without clearing its owner")
    func expiredSessionPreservesLastOwner() {
        let expired = AuthHydrationOutcome.resolve(
            lastOwnerUserId: "user-1",
            clerkUserId: nil
        )
        let repeated = AuthHydrationOutcome.resolve(
            lastOwnerUserId: "user-1",
            clerkUserId: nil
        )

        #expect(expired == .signedOutPreservingAccount)
        #expect(repeated == .signedOutPreservingAccount)
        #expect(!expired.requiresAccountTeardown)
    }

    @Test("A transient missing user resumes the same account")
    func transientMissingUserResumesSameAccount() {
        let missing = AuthHydrationOutcome.resolve(
            lastOwnerUserId: "user-1",
            clerkUserId: nil
        )
        let resumed = AuthHydrationOutcome.resolve(
            lastOwnerUserId: "user-1",
            clerkUserId: "user-1"
        )

        #expect(missing == .signedOutPreservingAccount)
        #expect(resumed == .authenticated)
        #expect(!resumed.requiresAccountTeardown)
    }

    @Test("Explicit sign-out always clears local account data")
    func explicitSignOutIsConfirmed() {
        let trigger = AccountTeardownTrigger.explicitSignOut

        #expect(trigger.isConfirmed(currentClerkUserId: nil))
        #expect(trigger.isConfirmed(currentClerkUserId: "user-1"))
    }

    @Test("A different user after a missing user requires account teardown")
    func missingUserThenDifferentUserRequiresTeardown() {
        let missing = AuthHydrationOutcome.resolve(
            lastOwnerUserId: "user-1",
            clerkUserId: nil
        )
        let switched = AuthHydrationOutcome.resolve(
            lastOwnerUserId: "user-1",
            clerkUserId: "user-2"
        )
        let trigger = AccountTeardownTrigger.accountSwitch(
            previousUserId: "user-1",
            newUserId: "user-2"
        )

        #expect(missing == .signedOutPreservingAccount)
        #expect(switched == .accountSwitch)
        #expect(switched.requiresAccountTeardown)
        #expect(trigger.isConfirmed(currentClerkUserId: "user-2"))
        #expect(!trigger.isConfirmed(currentClerkUserId: nil))
        #expect(!trigger.isConfirmed(currentClerkUserId: "user-1"))
    }

    @Test("A missing local key keeps passkey recovery available")
    func missingLocalKeyAllowsPasskeyRecovery() {
        #expect(shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: false))
        #expect(!shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: true))
    }
}
