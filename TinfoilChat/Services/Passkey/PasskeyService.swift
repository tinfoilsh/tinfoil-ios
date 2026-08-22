//
//  PasskeyService.swift
//  TinfoilChat
//
//  App compatibility facade for TinfoilPasskeyKit.
//

import Foundation
import TinfoilPasskeyKit

enum PasskeyError: LocalizedError {
    case prfNotSupported
    case prfOutputMissing
    case userCancelled
    case authorizationFailed(Error)
    case randomGenerationFailed
    case invalidBase64url
    case presentationAnchorUnavailable

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
        case .randomGenerationFailed:
            return "Failed to generate secure random bytes"
        case .invalidBase64url:
            return "Invalid base64url-encoded credential ID"
        case .presentationAnchorUnavailable:
            return "Passkey authorization requires an active app window"
        }
    }
}

@MainActor
final class PasskeyService {
    static let shared = PasskeyService()

    private let storage: TinfoilPasskeyKeyStorage
    private let presentationAnchorProvider: TinfoilPasskeyPresentationAnchorProvider
    private let keyManagerResult: Result<PasskeyKeyManager, Error>

    private init() {
        let storage = TinfoilPasskeyKeyStorage()
        let presentationAnchorProvider = TinfoilPasskeyPresentationAnchorProvider()
        self.storage = storage
        self.presentationAnchorProvider = presentationAnchorProvider
        do {
            keyManagerResult = .success(try PasskeyKeyManager(
                profile: TinfoilPasskeyProfile.current,
                relyingPartyName: Constants.Passkey.rpName,
                storage: storage,
                presentationAnchorProvider: presentationAnchorProvider
            ))
        } catch {
            keyManagerResult = .failure(error)
        }
    }

    func createAndWrapKey(
        userId: String,
        userEmail: String,
        displayName: String,
        key: Data
    ) async throws -> CreatedWrappedKey {
        do {
            try presentationAnchorProvider.requirePresentationAnchor()
            let keyManager = try keyManager()
            return try await keyManager.createAndWrapKey(
                user: PasskeyUser(
                    id: Data(userId.utf8),
                    name: userEmail,
                    displayName: displayName
                ),
                key: key
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func recoverKey(
        wrappedKeys: [WrappedKey],
        preferredCredentialId: String? = nil,
        immediatelyAvailable: Bool = false
    ) async throws -> RecoveredKey {
        do {
            try presentationAnchorProvider.requirePresentationAnchor()
            let keyManager = try keyManager()
            return try await keyManager.recoverKey(
                wrappedKeys: wrappedKeys,
                preferredCredentialId: preferredCredentialId,
                interaction: Self.interaction(immediatelyAvailable: immediatelyAvailable)
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func wrapKeyWithPRFResult(
        key: Data,
        credentialId: String,
        prfResult: PRFResult
    ) throws -> WrappedKey {
        do {
            let keyManager = try keyManager()
            return try keyManager.wrapKeyWithPRFResult(
                keyMaterial: key,
                credentialId: credentialId,
                prfResult: prfResult
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func unwrapKeyWithPRFResult(
        wrappedKey: WrappedKey,
        prfResult: PRFResult
    ) throws -> Data {
        do {
            let keyManager = try keyManager()
            return try keyManager.unwrapKeyWithPRFResult(
                wrappedKey: wrappedKey,
                prfResult: prfResult
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func cachedPRFResult(for credentialIds: [String]? = nil) -> CachedPRFResult? {
        guard let result = try? storage.loadCachedPRFResult(),
              result.profile == TinfoilPasskeyProfile.current else {
            return nil
        }
        guard let credentialIds else { return result }
        return credentialIds.contains(result.credentialId) ? result : nil
    }

    func evaluateCredential(
        credentialIds: [String],
        preferredCredentialId: String? = nil,
        immediatelyAvailable: Bool
    ) async throws -> EvaluatedCredential {
        do {
            try presentationAnchorProvider.requirePresentationAnchor()
            let keyManager = try keyManager()
            return try await keyManager.evaluateCredential(
                credentialIds: credentialIds,
                preferredCredentialId: preferredCredentialId,
                interaction: Self.interaction(immediatelyAvailable: immediatelyAvailable)
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func clearCachedPrfResult() {
        if case .success(let keyManager) = keyManagerResult {
            keyManager.clearLocalState()
        }
    }

    private func keyManager() throws -> PasskeyKeyManager {
        do {
            return try keyManagerResult.get()
        } catch {
            throw PasskeyError.authorizationFailed(error)
        }
    }

    nonisolated static func interaction(immediatelyAvailable: Bool) -> PasskeyInteraction {
        immediatelyAvailable ? .immediatelyAvailable : .interactive
    }

    nonisolated static func mapError(_ error: Error) -> PasskeyError {
        if let passkeyError = error as? PasskeyError {
            return passkeyError
        }
        guard let passkeyError = error as? PasskeyKeyError else {
            return .authorizationFailed(error)
        }
        switch passkeyError {
        case .unsupported:
            return .prfNotSupported
        case .cancelled:
            return .userCancelled
        case .timeout, .operationInProgress, .invalidInput, .operationFailed:
            return .authorizationFailed(passkeyError)
        }
    }
}
