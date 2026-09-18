struct OnboardingFlow {
    enum Page: Int, CaseIterable {
        case letter
        case privacy
        case safeguards
    }

    private(set) var page: Page = .letter
    var privacyEnabled = false
    private(set) var isCompleted = false

    var continueTitle: String {
        page == .safeguards ? "Get Started" : "Continue"
    }

    mutating func advance() -> Bool {
        guard !isCompleted else { return false }
        switch page {
        case .letter:
            page = .privacy
        case .privacy:
            if privacyEnabled {
                page = .safeguards
            } else {
                privacyEnabled = true
            }
        case .safeguards:
            isCompleted = true
        }
        return isCompleted
    }
}

enum OnboardingEligibility {
    static func shouldShow(
        isAuthLoaded: Bool,
        isAuthenticated: Bool,
        userId: String?,
        localUserId: String?,
        hasCompletedLocally: Bool,
        hasCompletedOnAccount: Bool
    ) -> Bool {
        guard isAuthLoaded,
              isAuthenticated,
              let userId,
              userId == localUserId else { return false }
        return !hasCompletedLocally && !hasCompletedOnAccount
    }
}
