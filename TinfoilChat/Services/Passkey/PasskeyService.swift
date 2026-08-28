//
//  PasskeyService.swift
//  TinfoilChat
//
//  App compatibility facade for TinfoilPasskeyKit.
//

import CryptoKit
import Foundation
import TinfoilPasskeyKit

typealias PrfPasskeyResult = PRFPasskeyResult

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

    private let kit: PasskeyKit

    private init() {
        let stateStore = KeychainPasskeyStateStore(
            service: Constants.Passkey.rpId,
            account: Constants.Passkey.prfCacheKeychainAccount,
            localCredentialIdKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
        )
        kit = PasskeyKit(
            configuration: PasskeyKitConfiguration(
                rpId: Constants.Passkey.rpId,
                rpName: Constants.Passkey.rpName,
                prfSalt: Constants.Passkey.prfSalt,
                hkdfInfo: Constants.Passkey.hkdfInfo,
                challengeByteCount: Constants.Passkey.challengeByteCount,
                stateStore: stateStore
            )
        )
    }

    func createPasskey(
        userId: String,
        userEmail: String,
        displayName: String
    ) async throws -> PrfPasskeyResult {
        do {
            return try await kit.createPasskey(
                for: PasskeyUser(
                    id: userId,
                    name: userEmail,
                    displayName: displayName
                )
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func authenticatePasskey(
        credentialIds: [String],
        silent: Bool = false
    ) async throws -> PrfPasskeyResult {
        do {
            return try await kit.authenticate(
                credentialIds: credentialIds,
                mode: silent ? .immediatelyAvailable : .interactive
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func getCachedPrfResult() -> PrfPasskeyResult? {
        kit.cachedPRFResult()
    }

    func clearCachedPrfResult() {
        kit.clearCachedPRFResult()
    }

    nonisolated static func deriveKeyEncryptionKey(from prfOutput: SymmetricKey) -> SymmetricKey {
        PasskeyCrypto.deriveKeyEncryptionKey(
            from: prfOutput,
            info: Constants.Passkey.hkdfInfo
        )
    }

    nonisolated static func base64urlEncode(_ data: Data) -> String {
        PasskeyCodec.base64URLEncode(data)
    }

    nonisolated static func base64urlDecode(_ string: String) throws -> Data {
        do {
            return try PasskeyCodec.base64URLDecode(string)
        } catch {
            throw PasskeyError.invalidBase64url
        }
    }

    private nonisolated static func mapError(_ error: Error) -> PasskeyError {
        guard let passkeyError = error as? PasskeyKitError else {
            return .authorizationFailed(error)
        }
        switch passkeyError {
        case .prfNotSupported:
            return .prfNotSupported
        case .prfOutputMissing:
            return .prfOutputMissing
        case .userCancelled:
            return .userCancelled
        case .authorizationFailed(let underlyingError):
            return .authorizationFailed(underlyingError)
        case .randomGenerationFailed:
            return .randomGenerationFailed
        case .invalidBase64URL:
            return .invalidBase64url
        case .operationInProgress, .noCredentialIDs, .noMatchingBundle,
             .invalidChallengeLength, .userHandleTooLong:
            return .authorizationFailed(passkeyError)
        }
    }
}
