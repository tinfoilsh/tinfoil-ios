import ClerkKit
import Combine
import Foundation

@MainActor
final class SignUpLegalConsent: ObservableObject {
    struct Details {
        let firstName: String?
        let lastName: String?
        let legalAccepted: Bool?
    }

    @Published var isAccepted = false
    @Published var firstName = ""
    @Published var lastName = ""
    @Published private(set) var pendingSignUp: SignUp?

    private let updateSignUp: @MainActor (SignUp, Details) async throws -> SignUp

    init(
        updateSignUp: @escaping @MainActor (SignUp, Details) async throws -> SignUp = { signUp, details in
            try await signUp.update(
                firstName: details.firstName,
                lastName: details.lastName,
                legalAccepted: details.legalAccepted
            )
        }
    ) {
        self.updateSignUp = updateSignUp
    }

    var hasCollectableRequirements: Bool {
        guard let signUp = pendingSignUp,
              signUp.status == .missingRequirements,
              !signUp.missingFields.isEmpty else { return false }
        return signUp.missingFields.allSatisfy { field in
            switch field {
            case .firstName, .lastName, .legalAccepted:
                return true
            default:
                return false
            }
        }
    }

    var canSubmit: Bool {
        guard hasCollectableRequirements, let signUp = pendingSignUp else { return false }
        return (!signUp.missingFields.contains(.legalAccepted) || isAccepted)
            && (!signUp.missingFields.contains(.firstName) || !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!signUp.missingFields.contains(.lastName) || !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Social authentication can return a verified identity whose sign-up still
    /// needs legal acceptance. Update that attempt, not a new email sign-up.
    func resolve(_ signUp: SignUp) async throws -> SignUp {
        pendingSignUp = signUp.status == .complete ? nil : signUp
        guard canSubmit else { return signUp }

        let details = Details(
            firstName: signUp.missingFields.contains(.firstName)
                ? firstName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            lastName: signUp.missingFields.contains(.lastName)
                ? lastName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            legalAccepted: signUp.missingFields.contains(.legalAccepted) ? isAccepted : nil
        )
        let updatedSignUp = try await updateSignUp(signUp, details)
        pendingSignUp = updatedSignUp.status == .complete ? nil : updatedSignUp
        return updatedSignUp
    }

    func reset() {
        isAccepted = false
        firstName = ""
        lastName = ""
        pendingSignUp = nil
    }
}
