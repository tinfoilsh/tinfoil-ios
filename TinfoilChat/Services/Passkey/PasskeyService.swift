//
//  PasskeyService.swift
//  TinfoilChat
//
//  WebAuthn PRF Create/Authenticate + HKDF Key Derivation
//
//  Uses ASAuthorizationController with the PRF extension to derive deterministic
//  32-byte secrets from a passkey's built-in pseudo-random function. These secrets
//  are processed through HKDF-SHA256 to produce an AES-256-GCM Key Encryption Key (KEK).
//

import AuthenticationServices
import CryptoKit
import Foundation

/// Result of a PRF-capable passkey operation (create or authenticate).
struct PrfPasskeyResult {
    /// Base64url-encoded credential ID
    let credentialId: String
    /// Raw PRF output as a SymmetricKey (32 bytes)
    let prfOutput: SymmetricKey
}

/// Errors specific to passkey operations.
enum PasskeyError: LocalizedError {
    case prfNotSupported
    case prfOutputMissing
    case userCancelled
    case authorizationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .prfNotSupported:
            return "Authenticator does not support PRF"
        case .prfOutputMissing:
            return "PRF output missing from assertion"
        case .userCancelled:
            return "User cancelled passkey operation"
        case .authorizationFailed(let error):
            return "Passkey authorization failed: \(error.localizedDescription)"
        }
    }
}

/// Handles passkey creation, authentication, and KEK derivation via PRF + HKDF.
final class PasskeyService: NSObject {
    static let shared = PasskeyService()

    private var authContinuation: CheckedContinuation<ASAuthorization, Error>?

    private override init() {
        super.init()
    }

    // MARK: - Create Passkey

    /// Create a new PRF-capable passkey for the given user.
    ///
    /// Returns the credential ID and PRF output. If the authenticator doesn't
    /// return PRF results during creation (per spec, this is optional), an
    /// immediate authentication is performed to obtain them.
    ///
    /// - Throws: `PasskeyError.userCancelled` if the user dismisses Face ID,
    ///           `PasskeyError.prfNotSupported` if PRF is not available.
    func createPasskey(
        userId: String,
        userEmail: String,
        displayName: String
    ) async throws -> PrfPasskeyResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Constants.Passkey.rpId
        )

        let challenge = Self.randomChallenge()
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: userEmail,
            userID: Data(userId.utf8)
        )
        request.userVerificationPreference = .required

        // PRF input for registration — request evaluation with our salt
        request.prf = .inputValues(.saltInput1(Constants.Passkey.prfSalt))

        let authorization: ASAuthorization
        do {
            authorization = try await performAuthorization(requests: [request])
        } catch {
            throw Self.mapAuthError(error)
        }

        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PasskeyError.prfNotSupported
        }

        let credentialId = Self.base64urlEncode(credential.credentialID)

        // Check PRF support and results from registration.
        // "Not all authenticators support evaluating the PRFs during credential
        //  creation so outputs may, or may not, be provided."
        // — W3C WebAuthn Level 3, §10.1.4
        guard let prfOutput = credential.prf else {
            throw PasskeyError.prfNotSupported
        }

        guard prfOutput.isSupported else {
            throw PasskeyError.prfNotSupported
        }

        // If PRF results were returned during creation, use them directly
        if let firstKey = prfOutput.first {
            return PrfPasskeyResult(credentialId: credentialId, prfOutput: firstKey)
        }

        // PRF supported but no results during create — do an immediate get()
        return try await authenticatePasskey(credentialIds: [credentialId])
    }

    // MARK: - Authenticate Passkey

    /// Authenticate with an existing PRF passkey to derive the PRF output.
    ///
    /// - Parameter credentialIds: Base64url-encoded credential IDs to allow.
    ///   Pass all known PRF credential IDs so the system can select the right one.
    /// - Parameter silent: When true, sets `preferImmediatelyAvailableCredentials`
    ///   so the system only checks locally-available credentials (iCloud Keychain,
    ///   installed password managers, etc.) without showing any UI on failure.
    ///   When false (default), the system shows its full passkey UI including
    ///   "Use a Device Nearby" for cross-device transport.
    /// - Returns: The matched credential ID and PRF output.
    /// - Throws: `PasskeyError.userCancelled` on dismissal,
    ///           `PasskeyError.prfOutputMissing` if the assertion lacks PRF data.
    func authenticatePasskey(
        credentialIds: [String],
        silent: Bool = false
    ) async throws -> PrfPasskeyResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Constants.Passkey.rpId
        )

        let challenge = Self.randomChallenge()
        let allowedCredentials = credentialIds.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(
                credentialID: Self.base64urlDecode($0)
            )
        }

        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowedCredentials
        request.userVerificationPreference = .required

        // PRF input for assertion — evaluate with our salt
        request.prf = .inputValues(.saltInput1(Constants.Passkey.prfSalt))

        let authorization: ASAuthorization
        do {
            authorization = try await performAuthorization(requests: [request], silent: silent)
        } catch {
            throw Self.mapAuthError(error)
        }

        guard let assertion = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.prfOutputMissing
        }

        guard let prfOutput = assertion.prf else {
            throw PasskeyError.prfOutputMissing
        }

        let credentialId = Self.base64urlEncode(assertion.credentialID)
        return PrfPasskeyResult(credentialId: credentialId, prfOutput: prfOutput.first)
    }

    // MARK: - Key Derivation

    /// Derive an AES-256-GCM Key Encryption Key (KEK) from PRF output using HKDF-SHA256.
    ///
    /// Raw PRF output is treated as Input Keying Material (IKM), not used directly.
    /// HKDF with a purpose-binding info string produces the final SymmetricKey.
    static func deriveKeyEncryptionKey(from prfOutput: SymmetricKey) -> SymmetricKey {
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: prfOutput,
            salt: Data(),
            info: Constants.Passkey.hkdfInfo,
            outputByteCount: 32
        )
    }

    // MARK: - Base64url Helpers

    /// Base64url-encode data (no padding, URL-safe alphabet).
    static func base64urlEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string back to Data.
    static func base64urlDecode(_ string: String) -> Data {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64) ?? Data()
    }

    // MARK: - Private Helpers

    /// Generate a random 32-byte challenge for WebAuthn ceremonies.
    private static func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Perform an ASAuthorizationController request and await the result.
    ///
    /// - Parameter silent: When true, sets `preferImmediatelyAvailableCredentials`
    ///   so the controller only checks locally-available credentials without
    ///   showing any UI if nothing matches.
    private func performAuthorization(
        requests: [ASAuthorizationRequest],
        silent: Bool = false
    ) async throws -> ASAuthorization {
        return try await withCheckedThrowingContinuation { continuation in
            self.authContinuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            if silent {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }
    }

    /// Map ASAuthorizationError to PasskeyError.
    private static func mapAuthError(_ error: Error) -> PasskeyError {
        if let authError = error as? ASAuthorizationError,
           authError.code == .canceled {
            return .userCancelled
        }
        return .authorizationFailed(error)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension PasskeyService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        authContinuation?.resume(returning: authorization)
        authContinuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        authContinuation?.resume(throwing: error)
        authContinuation = nil
    }
}
