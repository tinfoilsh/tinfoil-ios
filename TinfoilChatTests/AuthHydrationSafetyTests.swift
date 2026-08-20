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

    @Test("A paused missing-user pass cannot replace same-owner recovery")
    func pausedMissingUserCannotReplaceSameOwnerRecovery() async {
        let overlap = AuthHydrationOverlapHarness()
        let missingUserPass = Task {
            await overlap.runMissingUserPass()
        }

        await overlap.waitUntilMissingUserPassIsPaused()
        await overlap.completeSameOwnerPass()
        await overlap.resumeMissingUserPass()
        await missingUserPass.value

        #expect(await overlap.authenticatedUserId == "user-1")
    }

    @Test("Explicit sign-out always clears local account data")
    func explicitSignOutIsConfirmed() {
        let trigger = AccountTeardownTrigger.explicitSignOut

        #expect(trigger.isConfirmed(currentClerkUserId: nil))
        #expect(trigger.isConfirmed(currentClerkUserId: "user-1"))
        #expect(trigger.ownerUserId(retainedOwnerUserId: "user-1") == "user-1")
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
        #expect(trigger.ownerUserId(retainedOwnerUserId: nil) == "user-1")
    }

    @Test("A missing local key keeps passkey recovery available")
    func missingLocalKeyAllowsPasskeyRecovery() {
        #expect(shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: false))
        #expect(!shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: true))
    }
}

private actor AuthHydrationOverlapHarness {
    private var generation = AuthHydrationGeneration()
    private var missingUserContinuation: CheckedContinuation<Void, Never>?
    private var pauseObserver: CheckedContinuation<Void, Never>?
    private var isMissingUserPassPaused = false
    private(set) var authenticatedUserId: String?

    func runMissingUserPass() async {
        let token = generation.advance()
        await withCheckedContinuation { continuation in
            missingUserContinuation = continuation
            isMissingUserPassPaused = true
            pauseObserver?.resume()
            pauseObserver = nil
        }
        guard generation.isCurrent(token) else { return }
        authenticatedUserId = nil
    }

    func waitUntilMissingUserPassIsPaused() async {
        guard !isMissingUserPassPaused else { return }
        await withCheckedContinuation { continuation in
            pauseObserver = continuation
        }
    }

    func completeSameOwnerPass() {
        let token = generation.advance()
        guard generation.isCurrent(token) else { return }
        authenticatedUserId = "user-1"
    }

    func resumeMissingUserPass() {
        missingUserContinuation?.resume()
        missingUserContinuation = nil
    }
}
