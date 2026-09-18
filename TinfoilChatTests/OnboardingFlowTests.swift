import Testing
@testable import TinfoilChat

struct OnboardingFlowTests {
    @Test func followsWebPageOrderAndCompletesOnlyAfterSafeguards() {
        var flow = OnboardingFlow()
        #expect(flow.page == .letter)
        #expect(flow.continueTitle == "Continue")
        #expect(!flow.advance())
        #expect(flow.page == .privacy)
        #expect(!flow.privacyEnabled)

        #expect(!flow.advance())
        #expect(flow.page == .privacy)
        #expect(flow.privacyEnabled)
        #expect(flow.continueTitle == "Continue")

        #expect(!flow.advance())
        #expect(flow.page == .safeguards)
        #expect(flow.continueTitle == "Get Started")
        #expect(!flow.isCompleted)
        #expect(flow.advance())
        #expect(flow.isCompleted)
        #expect(!flow.advance())
    }

    @Test func manuallyEnablingPrivacyAllowsTheNextContinueToAdvance() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        flow.privacyEnabled = true
        #expect(!flow.advance())
        #expect(flow.page == .safeguards)
    }

    @Test func turningPrivacyBackOffRequiresConfirmationAgain() {
        var flow = OnboardingFlow()
        _ = flow.advance()
        flow.privacyEnabled = true
        flow.privacyEnabled = false
        #expect(!flow.advance())
        #expect(flow.page == .privacy)
        #expect(flow.privacyEnabled)
    }

    @Test func aNewFlowStartsWithTheLetterAndPrivacyDisabled() {
        var completedFlow = OnboardingFlow()
        completedFlow.privacyEnabled = true
        for _ in OnboardingFlow.Page.allCases {
            _ = completedFlow.advance()
        }
        #expect(completedFlow.isCompleted)
        let replay = OnboardingFlow()
        #expect(replay.page == .letter)
        #expect(!replay.privacyEnabled)
        #expect(!replay.isCompleted)
    }

    @Test func requiresLoadedMatchingAuthentication() {
        #expect(eligible())
        #expect(!eligible(isAuthLoaded: false))
        #expect(!eligible(isAuthenticated: false))
        #expect(!eligible(userId: nil))
        #expect(!eligible(localUserId: nil))
        #expect(!eligible(localUserId: "another-user"))
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func honorsDeviceAndAccountCompletion(completion: (Bool, Bool)) {
        #expect(!eligible(hasCompletedLocally: completion.0, hasCompletedOnAccount: completion.1))
    }

    private func eligible(
        isAuthLoaded: Bool = true,
        isAuthenticated: Bool = true,
        userId: String? = "current-user",
        localUserId: String? = "current-user",
        hasCompletedLocally: Bool = false,
        hasCompletedOnAccount: Bool = false
    ) -> Bool {
        OnboardingEligibility.shouldShow(
            isAuthLoaded: isAuthLoaded,
            isAuthenticated: isAuthenticated,
            userId: userId,
            localUserId: localUserId,
            hasCompletedLocally: hasCompletedLocally,
            hasCompletedOnAccount: hasCompletedOnAccount
        )
    }
}
