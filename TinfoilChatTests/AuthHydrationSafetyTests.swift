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
        #expect(!trigger.isConfirmed(currentClerkUserId: "user-2"))
        #expect(trigger.isConfirmed(currentClerkUserId: nil))
        #expect(!trigger.isConfirmed(currentClerkUserId: "user-1"))
        #expect(trigger.ownerUserId(retainedOwnerUserId: nil) == "user-1")
    }

    @Test("A profile cannot sync during a passive switch to B")
    func passiveSwitchPausesProfileAccess() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")

        hydration.observe(clerkUserId: "user-A")
        hydration.requestProfileSync()
        hydration.observe(clerkUserId: "user-B")
        hydration.requestProfileSync()

        #expect(hydration.deletedOwnerUserIds.isEmpty)
        #expect(hydration.activeUserId == nil)
        #expect(hydration.requiresExplicitRetry)
        #expect(hydration.profileSyncUserIds == ["user-A"])
    }

    @Test("B to A recovery resumes profile access for A")
    func switchReversalResumesOwnerProfile() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")

        hydration.observe(clerkUserId: "user-A")
        hydration.observe(clerkUserId: "user-B")
        hydration.observe(clerkUserId: "user-A")
        hydration.requestProfileSync()

        #expect(hydration.deletedOwnerUserIds.isEmpty)
        #expect(hydration.activeUserId == "user-A")
        #expect(!hydration.requiresExplicitRetry)
        #expect(hydration.profileSyncUserIds == ["user-A"])
    }

    @Test("Clerk sign-out failure preserves A local data")
    func clerkSignOutFailurePreservesOwner() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")
        hydration.observe(clerkUserId: "user-B")

        hydration.confirmAccountSwitch(signOutSucceeds: false)

        #expect(hydration.deletedOwnerUserIds.isEmpty)
        #expect(hydration.clerkUserId == "user-B")
        #expect(hydration.requiresExplicitRetry)
    }

    @Test("Successful confirmation signs out B before clearing A")
    func confirmationSignsOutSessionBeforeClearingOwner() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")
        hydration.observe(clerkUserId: "user-B")

        hydration.confirmAccountSwitch(signOutSucceeds: true)

        #expect(hydration.deletedOwnerUserIds == ["user-A"])
        #expect(hydration.operations == ["signOut:user-B", "clear:user-A"])
        #expect(hydration.clerkUserId == nil)
        #expect(hydration.activeUserId == nil)
        #expect(!hydration.requiresExplicitRetry)
    }

    @Test("Account switch cleanup never automatically activates B")
    func accountSwitchCleanupFinishesSignedOut() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")
        hydration.observe(clerkUserId: "user-B")

        hydration.confirmAccountSwitch(signOutSucceeds: true)
        hydration.observe(clerkUserId: nil)

        #expect(hydration.activeUserId == nil)
        #expect(hydration.ownerUserId == nil)
    }

    @Test("Explicit cleanup resumes profile access only after a later sign-in")
    func cleanupRequiresFutureValidatedSignIn() {
        var hydration = AuthSwitchSafetyHarness(ownerUserId: "user-A")
        hydration.observe(clerkUserId: "user-A")
        hydration.observe(clerkUserId: "user-B")

        hydration.confirmAccountSwitch(signOutSucceeds: true)
        hydration.requestProfileSync()
        #expect(hydration.profileSyncUserIds.isEmpty)

        hydration.observe(clerkUserId: "user-B")
        hydration.requestProfileSync()

        #expect(hydration.activeUserId == "user-B")
        #expect(hydration.profileSyncUserIds == ["user-B"])
    }

    @Test("An ordinary teardown retry does not sign Clerk out again")
    func ordinaryTeardownRetrySkipsClerkSignOut() {
        let retry = AccountTeardownRetryReason.teardownFailure(.explicitSignOut)

        #expect(!retry.requiresClerkSignOut)
    }

    @Test("A missing local key keeps passkey recovery available")
    func missingLocalKeyAllowsPasskeyRecovery() {
        #expect(shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: false))
        #expect(!shouldAttemptPasskeyRecovery(hasLocalEncryptionKey: true))
    }
}

private struct AuthSwitchSafetyHarness {
    private(set) var ownerUserId: String?
    private(set) var clerkUserId: String?
    private(set) var activeUserId: String?
    private(set) var deletedOwnerUserIds: [String] = []
    private(set) var operations: [String] = []
    private(set) var requiresExplicitRetry = false
    private(set) var profileAccessReady = false
    private(set) var profileSyncUserIds: [String] = []

    mutating func observe(clerkUserId: String?) {
        self.clerkUserId = clerkUserId
        if requiresExplicitRetry {
            if clerkUserId == ownerUserId {
                requiresExplicitRetry = false
            } else {
                activeUserId = nil
                profileAccessReady = false
                return
            }
        }
        profileAccessReady = false
        switch AuthHydrationOutcome.resolve(
            lastOwnerUserId: ownerUserId,
            clerkUserId: clerkUserId
        ) {
        case .signedOut, .signedOutPreservingAccount:
            activeUserId = nil
        case .authenticated:
            activeUserId = clerkUserId
            ownerUserId = clerkUserId
            requiresExplicitRetry = false
            profileAccessReady = true
        case .accountSwitch:
            activeUserId = nil
            requiresExplicitRetry = true
        }
    }

    mutating func requestProfileSync() {
        guard profileAccessReady, let activeUserId else { return }
        profileSyncUserIds.append(activeUserId)
    }

    mutating func confirmAccountSwitch(signOutSucceeds: Bool) {
        guard requiresExplicitRetry else { return }
        if let clerkUserId {
            operations.append("signOut:\(clerkUserId)")
            guard signOutSucceeds else { return }
            self.clerkUserId = nil
        }
        let trigger = AccountTeardownTrigger.accountSwitch(
            previousUserId: ownerUserId ?? "",
            newUserId: "user-B"
        )
        guard trigger.isConfirmed(currentClerkUserId: clerkUserId) else { return }
        if let ownerUserId {
            operations.append("clear:\(ownerUserId)")
            deletedOwnerUserIds.append(ownerUserId)
        }
        ownerUserId = nil
        activeUserId = nil
        requiresExplicitRetry = false
        profileAccessReady = false
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
