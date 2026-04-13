import ClerkKit
import CryptoKit
import Foundation

typealias CloudKeySnapshot = (primary: String?, alternatives: [String])

enum CloudKeyAuthorizationMode: String, Codable {
    case validated
    case explicitStartFresh
}

enum CloudKeyAuthorizationError: LocalizedError {
    case validationFailed(String)
    case rollbackFailed(underlying: Error)
    case authorizationUnavailable

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message):
            return message
        case .rollbackFailed(let underlying):
            return "Failed to restore the previous encryption key: \(underlying.localizedDescription)"
        case .authorizationUnavailable:
            return "Failed to authorize the current encryption key."
        }
    }
}

private struct CloudKeyAuthorizationRecord: Codable {
    let fingerprint: String
    let mode: CloudKeyAuthorizationMode
}

@MainActor
final class CloudKeyAuthorizationStore {
    static let shared = CloudKeyAuthorizationStore()

    private init() {}

    func currentMode(userId: String? = nil) -> CloudKeyAuthorizationMode? {
        guard let resolvedUserId = resolveUserId(userId),
              let record = loadRecord(userId: resolvedUserId),
              let currentFingerprint = currentPrimaryKeyFingerprint(),
              record.fingerprint == currentFingerprint else {
            return nil
        }

        return record.mode
    }

    func hasAuthorizedCurrentPrimaryKey(userId: String? = nil) -> Bool {
        currentMode(userId: userId) != nil
    }

    func authorizeCurrentPrimaryKey(
        mode: CloudKeyAuthorizationMode,
        userId: String? = nil
    ) -> Bool {
        guard let resolvedUserId = resolveUserId(userId),
              let currentFingerprint = currentPrimaryKeyFingerprint() else {
            return false
        }

        let record = CloudKeyAuthorizationRecord(
            fingerprint: currentFingerprint,
            mode: mode
        )

        do {
            let data = try JSONEncoder().encode(record)
            UserDefaults.standard.set(data, forKey: storageKey(userId: resolvedUserId))
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: storageKey(userId: resolvedUserId))
            return false
        }
    }

    func clearAuthorization(userId: String? = nil) {
        guard let resolvedUserId = resolveUserId(userId) else { return }
        UserDefaults.standard.removeObject(forKey: storageKey(userId: resolvedUserId))
    }

    func applyKeyBundleWithValidation(
        primary: String,
        alternatives: [String],
        successMode: CloudKeyAuthorizationMode = .validated,
        failureMode: CloudKeyAuthorizationMode? = nil
    ) async throws -> CloudKeyAuthorizationMode {
        return try await applyAndValidate(
            setKeys: {
                try await EncryptionService.shared.setAllKeys(primary: primary, alternatives: alternatives)
            },
            successMode: successMode,
            failureMode: failureMode
        )
    }

    func applyPrimaryKeyWithValidation(
        _ key: String,
        successMode: CloudKeyAuthorizationMode = .validated,
        failureMode: CloudKeyAuthorizationMode? = nil
    ) async throws -> CloudKeyAuthorizationMode {
        return try await applyAndValidate(
            setKeys: {
                try await EncryptionService.shared.setKey(key)
            },
            successMode: successMode,
            failureMode: failureMode
        )
    }

    private func applyAndValidate(
        setKeys: () async throws -> Void,
        successMode: CloudKeyAuthorizationMode,
        failureMode: CloudKeyAuthorizationMode?
    ) async throws -> CloudKeyAuthorizationMode {
        let previousKeys = EncryptionService.shared.getAllKeys()
        do {
            try await setKeys()
        } catch let setKeysError {
            do {
                try rollbackToPreviousKeys(previousKeys)
            } catch let rollbackError {
                throw rollbackError
            }
            throw setKeysError
        }

        return try await authorizeCurrentPrimaryKeyAfterValidation(
            rollbackTo: previousKeys,
            successMode: successMode,
            failureMode: failureMode
        )
    }

    func authorizeCurrentPrimaryKeyAfterValidation(
        rollbackTo previousKeys: CloudKeySnapshot,
        successMode: CloudKeyAuthorizationMode = .validated,
        failureMode: CloudKeyAuthorizationMode? = nil
    ) async throws -> CloudKeyAuthorizationMode {
        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
        guard validation.canWrite else {
            if let failureMode {
                guard authorizeCurrentPrimaryKey(mode: failureMode) else {
                    try rollbackToPreviousKeys(previousKeys)
                    throw CloudKeyAuthorizationError.authorizationUnavailable
                }
                return failureMode
            }

            try rollbackToPreviousKeys(previousKeys)
            throw CloudKeyAuthorizationError.validationFailed(
                validation.message ?? CloudKeyPreflightValidator.mismatchMessage
            )
        }

        guard authorizeCurrentPrimaryKey(mode: successMode) else {
            try rollbackToPreviousKeys(previousKeys)
            throw CloudKeyAuthorizationError.authorizationUnavailable
        }
        return successMode
    }

    private func resolveUserId(_ userId: String?) -> String? {
        userId ?? Clerk.shared.user?.id
    }

    private func storageKey(userId: String) -> String {
        Constants.StorageKeys.Secret.cloudKeyAuthorization(userId: userId)
    }

    private func loadRecord(userId: String) -> CloudKeyAuthorizationRecord? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(userId: userId)) else {
            return nil
        }

        return try? JSONDecoder().decode(CloudKeyAuthorizationRecord.self, from: data)
    }

    private func currentPrimaryKeyFingerprint() -> String? {
        guard let key = EncryptionService.shared.getKey() else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func rollbackToPreviousKeys(_ previousKeys: CloudKeySnapshot) throws {
        do {
            try EncryptionService.shared.replaceKeyBundle(
                primary: previousKeys.primary,
                alternatives: previousKeys.alternatives
            )
        } catch let rollbackError {
            EncryptionService.shared.clearKey()
            clearAuthorization()
            throw CloudKeyAuthorizationError.rollbackFailed(underlying: rollbackError)
        }
    }
}
