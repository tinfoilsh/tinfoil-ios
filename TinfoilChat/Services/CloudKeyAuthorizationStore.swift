import Foundation

typealias CloudKeySnapshot = (primary: String?, alternatives: [String])

enum CloudKeyAuthorizationMode {
    case validated
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

/// Puts a key in place only once the registry accepts it, and registers
/// the held key where the registry has none. Whether a key may open the
/// account's chats is read from the registry each time, never kept.
@MainActor
final class CloudKeyAuthorizationStore {
    static let shared = CloudKeyAuthorizationStore()

    private init() {}

    /// `.validated` once the chat service accepted the held key for the
    /// account's chats on its last load, as the account reports it live.
    func currentMode() -> CloudKeyAuthorizationMode? {
        KeyRegistry.shared.keyAccepted ? .validated : nil
    }

    /// Stage a new key in memory, ask the registry to confirm it, and only
    /// then write it to the Keychain. On failure the staged key is dropped
    /// so a key the registry rejects is never persisted locally.
    func applyPrimaryKeyWithValidation(_ key: String) async throws {
        do {
            try await EncryptionService.shared.setKey(key, persist: false)
        } catch let stageError {
            EncryptionService.shared.discardStagedKeyState()
            throw stageError
        }

        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
        guard validation.canWrite else {
            EncryptionService.shared.discardStagedKeyState()
            throw CloudKeyAuthorizationError.validationFailed(
                validation.message ?? CloudKeyPreflightValidator.mismatchMessage
            )
        }

        do {
            try EncryptionService.shared.persistCurrentKeyState()
        } catch {
            EncryptionService.shared.discardStagedKeyState()
            throw CloudKeyAuthorizationError.authorizationUnavailable
        }
    }

    /// Make the current (staged or persisted) primary CEK the registry's
    /// key for an explicit "start fresh". When existing cloud data sits
    /// under a different key, the chat service refuses the new key; the
    /// only way past it is registering with created_via=start_fresh,
    /// which atomically drops the old rows and rebinds the user to this
    /// CEK.
    ///
    /// No-op only when the registry's key already IS this CEK (matching
    /// key id) — a prior ceremony that registered it must not be wiped
    /// again. Every other state registers, including an empty remote and
    /// unregistered legacy data: start-fresh still needs the registry's
    /// key, or the chat service refuses every stored chat request under
    /// it. Throws when the registry can't be reached so the caller
    /// surfaces "try again" instead of stranding a local-only key the
    /// registry never accepted.
    func registerStartFreshKeyIfNeeded() async throws {
        let cek = try EncryptionService.shared.getKeyBytesOrThrow()
        let keyB64 = cek.base64EncodedString()

        let current: KeyState
        do {
            current = try await KeyRegistry.shared.current()
        } catch {
            throw CloudKeyAuthorizationError.validationFailed(
                CloudKeyPreflightValidator.unknownRemoteStateMessage
            )
        }

        if let remoteKeyId = current.keyId,
           let localKeyId = try? ContentKeyBundle.deriveKeyIdHex(cek: cek),
           localKeyId == remoteKeyId {
            return
        }

        _ = try await KeyRegistry.shared.register(key: keyB64, ifMatch: current.etag ?? KeyRegistry.noKey, createdVia: .startFresh)
    }

    /// Makes the held key the account's where the registry has none, and
    /// has the harness reseal under it the rows older keys sealed. An
    /// account whose rows predate the registry registers the key as the
    /// one that recovers them; an account without rows, as entered by hand.
    /// The harness reseals only under the registered key, and owns the
    /// resealing once asked.
    func registerHeldKeyIfNeeded() async throws {
        let held = EncryptionService.shared.getAllKeys()
        guard let primary = held.primary, let primaryBytes = try? EncryptionService.shared.getAlternativeKeyBytes(primary) else { return }
        let current = try await KeyRegistry.shared.current()
        let target = primaryBytes.base64EncodedString()
        if let keyId = current.keyId {
            guard current.hasData, keyId == (try? ContentKeyBundle.deriveKeyIdHex(cek: primaryBytes)) else { return }
        } else {
            _ = try await KeyRegistry.shared.register(key: target, ifMatch: KeyRegistry.noKey, createdVia: current.hasData ? .recovery : .manual)
            guard current.hasData else { return }
        }
        // Every key this device holds may have sealed a row.
        var keys = [target]
        for alternative in held.alternatives where alternative != primary {
            guard let bytes = try? EncryptionService.shared.getAlternativeKeyBytes(alternative) else { continue }
            keys.append(bytes.base64EncodedString())
        }
        try await KeyRegistry.shared.migrateAll(keys: keys, target: target)
    }

    /// Keeps the key just set when the registry accepts it, and otherwise
    /// puts the previous keys back.
    func validateCurrentPrimaryKey(rollingBackTo previousKeys: CloudKeySnapshot) async throws {
        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
        guard validation.canWrite else {
            try rollbackToPreviousKeys(previousKeys)
            throw CloudKeyAuthorizationError.validationFailed(
                validation.message ?? CloudKeyPreflightValidator.mismatchMessage
            )
        }
    }

    private func rollbackToPreviousKeys(_ previousKeys: CloudKeySnapshot) throws {
        do {
            try EncryptionService.shared.replaceKeyBundle(
                primary: previousKeys.primary,
                alternatives: previousKeys.alternatives
            )
        } catch let rollbackError {
            EncryptionService.shared.clearKey()
            throw CloudKeyAuthorizationError.rollbackFailed(underlying: rollbackError)
        }
    }
}
