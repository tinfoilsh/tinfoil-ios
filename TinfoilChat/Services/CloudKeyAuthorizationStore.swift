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
            stageKeys: {
                try await EncryptionService.shared.setAllKeys(
                    primary: primary,
                    alternatives: alternatives,
                    persist: false
                )
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
            stageKeys: {
                try await EncryptionService.shared.setKey(key, persist: false)
            },
            successMode: successMode,
            failureMode: failureMode
        )
    }

    /// Stage a new key in memory, ask the enclave to confirm it, and only
    /// then write it to the Keychain. On failure the staged key is dropped
    /// so a key the enclave rejects is never persisted locally.
    private func applyAndValidate(
        stageKeys: () async throws -> Void,
        successMode: CloudKeyAuthorizationMode,
        failureMode: CloudKeyAuthorizationMode?
    ) async throws -> CloudKeyAuthorizationMode {
        do {
            try await stageKeys()
        } catch let stageError {
            EncryptionService.shared.discardStagedKeyState()
            throw stageError
        }

        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
        guard validation.canWrite else {
            if let failureMode {
                return try commitStagedKey(mode: failureMode)
            }
            EncryptionService.shared.discardStagedKeyState()
            throw CloudKeyAuthorizationError.validationFailed(
                validation.message ?? CloudKeyPreflightValidator.mismatchMessage
            )
        }

        return try commitStagedKey(mode: successMode)
    }

    /// Persist the staged key (the enclave accepted it, or the caller
    /// explicitly chose to proceed) and stamp the local mode hint.
    private func commitStagedKey(
        mode: CloudKeyAuthorizationMode
    ) throws -> CloudKeyAuthorizationMode {
        do {
            try EncryptionService.shared.persistCurrentKeyState()
        } catch {
            EncryptionService.shared.discardStagedKeyState()
            throw CloudKeyAuthorizationError.authorizationUnavailable
        }
        // The mode hint is best-effort local state: failing to stamp
        // it (e.g. no resolvable user id during a session blip) must
        // never destroy the key the enclave just accepted and the
        // Keychain just persisted. Without the hint, writes stay
        // gated until a later preflight validation re-stamps it.
        guard authorizeCurrentPrimaryKey(mode: mode) else {
            throw CloudKeyAuthorizationError.authorizationUnavailable
        }
        return mode
    }

    /// Make the current (staged or persisted) primary CEK the enclave's
    /// authoritative key for an explicit "start fresh". When existing
    /// cloud data sits under a different key, the steady-state write guard
    /// blocks the new key; the only way past it is register-key with
    /// created_via=start_fresh, which atomically drops the old rows and
    /// rebinds the user to this CEK.
    ///
    /// No-op only when the enclave's registered key already IS this CEK
    /// (matching key id) — a prior ceremony that registered it must not
    /// be wiped again. Every other state registers, including an empty
    /// remote and unregistered legacy data: start-fresh still needs the
    /// enclave-side key row, or every subsequent push is rejected as a
    /// stale key. Throws when the enclave can't be reached so the caller
    /// surfaces "try again" instead of stranding a local-only key the
    /// enclave never accepted.
    func registerStartFreshKeyIfNeeded() async throws {
        let cek = try EncryptionService.shared.getKeyBytesOrThrow()
        let keyB64 = cek.base64EncodedString()

        let current: EnclaveKeyCurrentResponse
        do {
            current = try await SyncEnclaveAPI.keyCurrent()
        } catch {
            throw CloudKeyAuthorizationError.validationFailed(
                CloudKeyPreflightValidator.unknownRemoteStateMessage
            )
        }

        if let remoteKeyId = current.keyId,
           let localKeyId = try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek),
           localKeyId == remoteKeyId {
            return
        }

        _ = try await SyncEnclaveAPI.registerKey(
            EnclaveKeyRegisterRequest(
                key: keyB64,
                ifMatch: current.etag ?? IfMatchSentinels.anyKey,
                createdVia: SyncEnclaveCreatedVia.startFresh.rawValue,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                initialBundle: nil
            )
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
