import ClerkKit
import Combine

@MainActor
final class SignUpLegalConsent: ObservableObject {
    @Published var isAccepted = false
    @Published private(set) var pendingSignUp: SignUp?

    private let updateSignUp: @MainActor (SignUp, Bool) async throws -> SignUp

    init(
        updateSignUp: @escaping @MainActor (SignUp, Bool) async throws -> SignUp = {
            try await $0.update(legalAccepted: $1)
        }
    ) {
        self.updateSignUp = updateSignUp
    }

    /// Social authentication can return a verified identity whose sign-up still
    /// needs legal acceptance. Update that attempt, not a new email sign-up.
    func resolve(_ signUp: SignUp) async throws -> SignUp {
        pendingSignUp = signUp.status == .complete ? nil : signUp
        guard signUp.status == .missingRequirements,
              signUp.missingFields.contains(.legalAccepted),
              isAccepted else {
            return signUp
        }

        let updatedSignUp = try await updateSignUp(signUp, isAccepted)
        pendingSignUp = updatedSignUp.status == .complete ? nil : updatedSignUp
        return updatedSignUp
    }

    func reset() {
        isAccepted = false
        pendingSignUp = nil
    }
}
