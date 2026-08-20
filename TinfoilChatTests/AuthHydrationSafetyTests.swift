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

    @Test("A different user waits for explicit account teardown")
    func differentUserWaitsForExplicitTeardown() {
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

    @Test("A to B passive switch does not delete data until retry")
    func passiveSwitchWaitsForRetry() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")

        hydration.observe(clerkUserId: "user-B")

        #expect(hydration.deletedOwnerUserIds.isEmpty)
        #expect(hydration.activeUserId == nil)
        #expect(hydration.requiresExplicitRetry)
    }

    @Test("B to A reversal resumes without deletion")
    func switchReversalResumesOwner() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")

        hydration.observe(clerkUserId: "user-B")
        hydration.observe(clerkUserId: "user-A")

        #expect(hydration.deletedOwnerUserIds.isEmpty)
        #expect(hydration.activeUserId == "user-A")
        #expect(!hydration.requiresExplicitRetry)
    }

    @Test("Explicit retry clears A and activates current B")
    func retryClearsOwnerAndActivatesCurrentUser() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")
        hydration.observe(clerkUserId: "user-B")

        hydration.retry(currentClerkUserId: "user-B")

        #expect(hydration.deletedOwnerUserIds == ["user-A"])
        #expect(hydration.activeUserId == "user-B")
        #expect(!hydration.requiresExplicitRetry)
    }

    @Test("A missing local key keeps passkey recovery available")
    func missingLocalKeyAllowsPasskeyRecovery() {
        #expect(shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: false))
        #expect(!shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: true))
    }
}

private struct AuthSwitchSafetyHarness {
    private(set) var ownerUserId: String?
    private(set) var activeUserId: String?
    private(set) var deletedOwnerUserIds: [String] = []
    private(set) var requiresExplicitRetry = false

    mutating func observe(clerkUserId: String?) {
        switch AuthHydrationOutcome.resolve(
            lastOwnerUserId: ownerUserId,
            clerkUserId: clerkUserId
        ) {
        case .signedOut, .signedOutPreservingAccount:
            activeUserId = nil
        case .authenticated:
            activeUserId = clerkUserId
            requiresExplicitRetry = false
        case .accountSwitch:
            activeUserId = nil
            requiresExplicitRetry = true
        }
    }

    mutating func retry(currentClerkUserId: String?) {
        switch AccountSwitchRetryOutcome.resolve(
            preservedOwnerUserId: ownerUserId,
            currentClerkUserId: currentClerkUserId
        ) {
        case .signedOutPreservingAccount:
            activeUserId = nil
            requiresExplicitRetry = false
        case .resumeSameOwner:
            activeUserId = currentClerkUserId
            requiresExplicitRetry = false
        case .teardown(let trigger):
            if let ownerUserId = trigger.ownerUserId(retainedOwnerUserId: ownerUserId) {
                deletedOwnerUserIds.append(ownerUserId)
            }
            ownerUserId = currentClerkUserId
            activeUserId = currentClerkUserId
            requiresExplicitRetry = false
        }
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
