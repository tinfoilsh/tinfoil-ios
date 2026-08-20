import Testing
@testable import TinfoilChat

@Suite("Authentication hydration safety")
struct AuthHydrationSafetyTests {
    @Test("A transient missing user preserves the cached account")
    func transientMissingUserPreservesCachedAccount() {
        let unavailable = AuthHydrationResolution.resolve(
            isCachedAuthenticated: true,
            cachedUserId: "user-1",
            clerkUserId: nil
        )
        let resumed = AuthHydrationResolution.resolve(
            isCachedAuthenticated: true,
            cachedUserId: "user-1",
            clerkUserId: "user-1"
        )

        #expect(unavailable == .sessionUnavailable)
        #expect(!unavailable.requiresAccountTeardown)
        #expect(resumed == .authenticated)
        #expect(!resumed.requiresAccountTeardown)
    }

    @Test("Explicit sign-out requires Clerk to report no user")
    func explicitSignOutIsRevalidated() {
        let trigger = AccountTeardownTrigger.explicitSignOut

        #expect(trigger.isConfirmed(currentClerkUserId: nil))
        #expect(!trigger.isConfirmed(currentClerkUserId: "user-1"))
    }

    @Test("An account switch requires the new Clerk account")
    func accountSwitchIsConfirmed() {
        let resolution = AuthHydrationResolution.resolve(
            isCachedAuthenticated: true,
            cachedUserId: "user-1",
            clerkUserId: "user-2"
        )
        let trigger = AccountTeardownTrigger.accountSwitch(
            previousUserId: "user-1",
            newUserId: "user-2"
        )

        #expect(resolution == .accountSwitch)
        #expect(resolution.requiresAccountTeardown)
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
