import ClerkKit
import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct SignUpLegalConsentTests {
    @Test
    func socialSignUpWaitsForExplicitConsent() async throws {
        let model = SignUpLegalConsent(updateSignUp: { signUp, _ in
            Issue.record("An unchecked consent box must not update Clerk")
            return signUp
        })
        let signUp = Self.pendingSignUp()

        let result = try await model.resolve(signUp)

        #expect(!model.isAccepted)
        #expect(result == signUp)
        #expect(model.pendingSignUp == signUp)
        #expect(result.createdSessionId == nil)
    }

    @Test
    func consentUpdatesTheSameSocialSignUpAndUsesClerksResult() async throws {
        let signUp = Self.pendingSignUp()
        var completedSignUp = signUp
        completedSignUp.status = .complete
        completedSignUp.missingFields = []
        completedSignUp.createdSessionId = "session-social"
        let model = SignUpLegalConsent(updateSignUp: { attempt, accepted in
            #expect(attempt == signUp)
            #expect(accepted)
            return completedSignUp
        })

        _ = try await model.resolve(signUp)
        model.isAccepted = true
        let pendingSignUp = try #require(model.pendingSignUp)
        let result = try await model.resolve(pendingSignUp)

        #expect(result == completedSignUp)
        #expect(model.pendingSignUp == nil)
    }

    @Test
    func consentCollectedBeforeSocialAuthIsSubmittedToClerk() async throws {
        var completedSignUp = Self.pendingSignUp()
        completedSignUp.status = .complete
        completedSignUp.missingFields = []
        completedSignUp.createdSessionId = "session-social"
        let model = SignUpLegalConsent(updateSignUp: { _, accepted in
            #expect(accepted)
            return completedSignUp
        })
        model.isAccepted = true

        let result = try await model.resolve(Self.pendingSignUp())

        #expect(result == completedSignUp)
        #expect(model.pendingSignUp == nil)
    }

    @Test
    func uncheckingConsentKeepsTheSignUpPending() async throws {
        let model = SignUpLegalConsent(updateSignUp: { signUp, _ in
            Issue.record("Revoked consent must not be sent to Clerk")
            return signUp
        })
        model.isAccepted = true
        model.isAccepted = false

        let result = try await model.resolve(Self.pendingSignUp())

        #expect(result.status == .missingRequirements)
        #expect(model.pendingSignUp == result)
    }

    @Test
    func failedConsentUpdatePreservesTheAttemptForRetry() async throws {
        let signUp = Self.pendingSignUp()
        var completedSignUp = signUp
        completedSignUp.status = .complete
        completedSignUp.missingFields = []
        completedSignUp.createdSessionId = "session-social"
        var attempts = 0
        let model = SignUpLegalConsent(updateSignUp: { attempt, accepted in
            #expect(attempt == signUp)
            #expect(accepted)
            attempts += 1
            if attempts == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return completedSignUp
        })
        model.isAccepted = true

        do {
            _ = try await model.resolve(signUp)
            Issue.record("Expected the network error to reach the UI")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
        #expect(model.pendingSignUp == signUp)
        #expect(model.isAccepted)

        let pendingSignUp = try #require(model.pendingSignUp)
        let result = try await model.resolve(pendingSignUp)

        #expect(attempts == 2)
        #expect(result == completedSignUp)
        #expect(model.pendingSignUp == nil)
    }

    @Test
    func acceptingLegalTermsDoesNotBypassOtherRequirements() async throws {
        let signUp = Self.pendingSignUp()
        var stillIncomplete = signUp
        stillIncomplete.missingFields = [.firstName]
        stillIncomplete.unverifiedFields = [.emailAddress]
        let model = SignUpLegalConsent(updateSignUp: { _, _ in stillIncomplete })
        model.isAccepted = true

        let result = try await model.resolve(signUp)

        #expect(result.status == .missingRequirements)
        #expect(result.createdSessionId == nil)
        #expect(model.pendingSignUp == stillIncomplete)
    }

    @Test
    func completedAbandonedAndUnrelatedAttemptsAreNotUpdated() async throws {
        let model = SignUpLegalConsent(updateSignUp: { signUp, _ in
            Issue.record("Only pending legal acceptance should update Clerk")
            return signUp
        })
        model.isAccepted = true
        var signUp = Self.pendingSignUp()
        signUp.missingFields = [.firstName]
        let incomplete = try await model.resolve(signUp)
        #expect(incomplete == signUp)
        #expect(model.pendingSignUp == signUp)

        signUp.missingFields = [.legalAccepted]
        signUp.status = .abandoned
        let abandoned = try await model.resolve(signUp)
        #expect(abandoned == signUp)

        signUp.status = .unknown("future_status")
        let unknown = try await model.resolve(signUp)
        #expect(unknown == signUp)

        signUp.status = .complete
        signUp.missingFields = []
        signUp.createdSessionId = "session-existing"
        let completed = try await model.resolve(signUp)
        #expect(completed == signUp)
        #expect(model.pendingSignUp == nil)
    }

    @Test
    func startingOverClearsConsentAndThePendingAttempt() async throws {
        let model = SignUpLegalConsent(updateSignUp: { signUp, _ in signUp })
        _ = try await model.resolve(Self.pendingSignUp())
        model.isAccepted = true

        model.reset()

        #expect(!model.isAccepted)
        #expect(model.pendingSignUp == nil)
    }

    private static func pendingSignUp() -> SignUp {
        SignUp(
            id: "signup-social",
            status: .missingRequirements,
            requiredFields: [.emailAddress, .legalAccepted],
            optionalFields: [],
            missingFields: [.legalAccepted],
            unverifiedFields: [],
            verifications: [:],
            emailAddress: "person@example.com",
            passwordEnabled: false,
            abandonAt: .distantFuture
        )
    }
}
