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
        }
    }
}

@MainActor
final class PasskeyService {
    static let shared = PasskeyService()

    private let storage: TinfoilPasskeyKeyStorage
    private let keyManager: PasskeyKeyManager

    private init() {
        let storage = TinfoilPasskeyKeyStorage()
        self.storage = storage
        keyManager = try! PasskeyKeyManager(
            profile: TinfoilPasskeyProfile.current,
            relyingPartyName: Constants.Passkey.rpName,
            storage: storage
        )
    }

    func createAndWrapKey(
        userId: String,
        userEmail: String,
        displayName: String,
        key: Data
    ) async throws -> CreatedWrappedKey {
        do {
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
            return try keyManager.unwrapKeyWithPRFResult(
                wrappedKey: wrappedKey,
                prfResult: prfResult
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func rewrapKeyFromCache(_ key: Data) throws -> WrappedKey? {
        do {
            return try keyManager.rewrapKeyFromCache(key: key)
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
        keyManager.clearLocalState()
    }

    nonisolated static func interaction(immediatelyAvailable: Bool) -> PasskeyInteraction {
        immediatelyAvailable ? .immediatelyAvailable : .interactive
    }

    nonisolated static func mapError(_ error: Error) -> PasskeyError {
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
