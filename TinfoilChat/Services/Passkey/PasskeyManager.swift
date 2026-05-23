//
//  PasskeyManager.swift
//  TinfoilChat
//
//  Manages passkey lifecycle on top of the attested sync enclave's
//  key registry (/v1/key/*). Mirrors the webapp's `usePasskeyBackup`
//  hook but exposes the same surface the iOS views already drive.
//

import ClerkKit
import CryptoKit
import Foundation

// MARK: - PasskeyRecoveryResult

enum PasskeyRecoveryResult {
    case success
    case newUserSetupDone
    case manualSetupRequired
    case manualRecoveryRequired
    case recoveryFailed
}

// MARK: - PasskeyManager

@MainActor
final class PasskeyManager: ObservableObject {
    static let shared = PasskeyManager()

    // MARK: - Published State

    @Published var passkeyActive: Bool = false
    @Published var passkeySetupAvailable: Bool = false
    @Published var showPasskeyRecoveryChoice: Bool = false

    // MARK: - Callbacks

    /// Called after successful recovery/fresh-start to resume the sign-in flow.
    var onRecoveryComplete: (() -> Void)?

    /// Called when the periodic sync check detects that another
    /// device started fresh and applied a new CEK to the enclave's
    /// key registry. The consumer should retry decryption of failed
    /// chats.
    var onKeyRefreshedFromBackup: (() -> Void)?

    // MARK: - Private

    private var syncCheckTask: Task<Void, Never>?
    private let passkeyService = PasskeyService.shared

    private init() {}

    // MARK: - Sign-Out Reset

    func reset() {
        passkeyActive = false
        passkeySetupAvailable = false
        showPasskeyRecoveryChoice = false
        onRecoveryComplete = nil
        onKeyRefreshedFromBackup = nil
        syncCheckTask?.cancel()
        syncCheckTask = nil
        passkeyService.clearCachedPrfResult()
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId)
    }

    // MARK: - Recovery Flow

    /// Attempt to recover encryption keys via passkey, or auto-generate for new users.
    func attemptPasskeyKeyRecovery() async -> PasskeyRecoveryResult {
        let state: EnclaveKeyCurrentResponse
        do {
            state = try await SyncEnclaveAPI.keyCurrent()
        } catch {
            #if DEBUG
            print("[PasskeyManager] keyCurrent failed: \(error)")
            #endif
            showPasskeyRecoveryChoice = true
            return .recoveryFailed
        }

        if state.keyId == nil || state.bundles.isEmpty {
            switch await CloudKeyPreflightValidator.shared.inspectRemoteState() {
            case .empty:
                let created = await attemptNewUserPasskeySetup()
                if !created {
                    passkeySetupAvailable = true
                }
                return created ? .newUserSetupDone : .manualSetupRequired
            case .exists, .unknown:
                passkeySetupAvailable = true
                return .manualRecoveryRequired
            }
        }

        let result = await PasskeyKeyFlow.unlockFromServer()
        switch result {
        case .success(let cek, let keyIdHex, let credentialId, _):
            do {
                try await applyRecoveredCek(cek: cek)
            } catch {
                #if DEBUG
                print("[PasskeyManager] Apply recovered CEK failed: \(error)")
                #endif
                showPasskeyRecoveryChoice = true
                return .recoveryFailed
            }
            persistEnclaveKeyState(keyIdHex: keyIdHex, credentialId: credentialId)
            activatePasskey()
            return .success
        case .failure(let reason, _):
            #if DEBUG
            print("[PasskeyManager] unlockFromServer failed: \(reason)")
            #endif
            showPasskeyRecoveryChoice = true
            return .recoveryFailed
        }
    }

    /// Auto-generate a key and create a passkey for a brand new user.
    @discardableResult
    private func attemptNewUserPasskeySetup(
        authorizationMode: CloudKeyAuthorizationMode = .validated
    ) async -> Bool {
        guard let user = userInfo() else { return false }
        let createdVia: SyncEnclaveCreatedVia = authorizationMode == .explicitStartFresh
            ? .startFresh
            : .passkey

        let result = await PasskeyKeyFlow.registerNewKeyWithPasskey(
            user: user,
            createdVia: createdVia
        )
        switch result {
        case .success(let cek, let keyIdHex, let credentialId, _):
            do {
                try await applyFreshCek(cek: cek)
                guard CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: authorizationMode) else {
                    EncryptionService.shared.clearKey()
                    throw CloudKeyAuthorizationError.authorizationUnavailable
                }
                persistEnclaveKeyState(keyIdHex: keyIdHex, credentialId: credentialId)
                activatePasskey()
                return true
            } catch {
                #if DEBUG
                print("[PasskeyManager] applyFreshCek failed: \(error)")
                #endif
                return false
            }
        case .failure(let reason, _):
            #if DEBUG
            print("[PasskeyManager] registerNewKeyWithPasskey failed: \(reason)")
            #endif
            return false
        }
    }

    // MARK: - Recovery Choice Actions

    func retryPasskeyRecovery() async -> Bool {
        let state: EnclaveKeyCurrentResponse
        do {
            state = try await SyncEnclaveAPI.keyCurrent()
        } catch {
            return false
        }
        guard state.keyId != nil, !state.bundles.isEmpty else { return false }

        let result = await PasskeyKeyFlow.unlockFromServer()
        switch result {
        case .success(let cek, let keyIdHex, let credentialId, _):
            do {
                try await applyRecoveredCek(cek: cek)
            } catch {
                return false
            }
            persistEnclaveKeyState(keyIdHex: keyIdHex, credentialId: credentialId)
            activatePasskey()
            showPasskeyRecoveryChoice = false
            onRecoveryComplete?()
            return true
        case .failure:
            return false
        }
    }

    func startFreshWithNewKey() async -> Bool {
        let success = await attemptNewUserPasskeySetup(authorizationMode: .explicitStartFresh)
        if success {
            showPasskeyRecoveryChoice = false
            onRecoveryComplete?()
        }
        return success
    }

    // MARK: - Setup & Backup

    /// Retry passkey setup. When an encryption key already exists,
    /// adds a new passkey bundle for the current CEK. When no key
    /// exists, runs the new-user flow that generates a key and
    /// registers it server-side in one step.
    func retryPasskeySetup() async -> PasskeyRecoveryResult {
        if EncryptionService.shared.hasEncryptionKey() {
            guard await ensureCurrentPrimaryKeyAuthorized() else {
                passkeySetupAvailable = true
                return .manualRecoveryRequired
            }
            await createPasskeyBackup()
            return .success
        }
        return await attemptPasskeyKeyRecovery()
    }

    /// Check passkey state for users who already have keys loaded.
    func checkPasskeyStateForExistingKey() async {
        do {
            let state = try await SyncEnclaveAPI.keyCurrent()
            if state.keyId != nil && !state.bundles.isEmpty {
                passkeyActive = true
                startSyncCheck()
                return
            }
        } catch {
            // fall through to "setup available"
        }
        passkeySetupAvailable = true
    }

    /// Create a passkey bundle for the user's existing CEK. Used by
    /// "Add this device to passkey backup" in Settings.
    func createPasskeyBackup() async {
        guard let user = userInfo() else { return }
        guard await ensureCurrentPrimaryKeyAuthorized() else { return }
        let cek: Data
        do {
            cek = try EncryptionService.shared.getKeyBytesOrThrow()
        } catch {
            return
        }
        let keyIdHex: String
        do {
            keyIdHex = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return
        }

        // Determine whether to register-key or add-bundle by probing
        // the enclave first. A 404 / nil key_id means "first time
        // ever", in which case we register the existing local CEK
        // with an initial bundle — never generate a fresh CEK here,
        // or we'd silently strand every local chat sealed under the
        // existing key.
        do {
            let state = try await SyncEnclaveAPI.keyCurrent()
            if state.keyId == nil {
                let result = await PasskeyKeyFlow.registerExistingKeyWithPasskey(
                    existingCek: cek,
                    user: user,
                    createdVia: .recovery
                )
                if case .success(_, _, let credentialId, _) = result {
                    persistEnclaveKeyState(keyIdHex: keyIdHex, credentialId: credentialId)
                    activatePasskey()
                }
                return
            }

            // Existing key — enroll a new passkey for it.
            let result = await PasskeyKeyFlow.addBundleForCurrentKey(
                cek: cek,
                keyIdHex: keyIdHex,
                user: user
            )
            if case .success(_, _, let credentialId, _) = result {
                persistEnclaveKeyState(keyIdHex: keyIdHex, credentialId: credentialId)
                activatePasskey()
            }
        } catch {
            // Non-fatal — leave state unchanged.
        }
    }

    /// No-op shim retained for compatibility with views that still
    /// call this on a periodic schedule. Bundles are immutable per
    /// credentialId on the new wire — each passkey's wrapped CEK is
    /// stable for the lifetime of that passkey. The only thing that
    /// can drift across devices is the key_id itself (start_fresh
    /// wipes), which the periodic sync check already handles.
    func updatePasskeyBackup() async {}

    // MARK: - Private Helpers

    private func activatePasskey() {
        SettingsManager.shared.isCloudSyncEnabled = true
        passkeyActive = true
        startSyncCheck()
    }

    private func applyRecoveredCek(cek: Data) async throws {
        let bytes = try await snapshotCurrentKeys()
        do {
            try await EncryptionService.shared.setKeyBytes(cek)
        } catch {
            try EncryptionService.shared.replaceKeyBundle(
                primary: bytes.primary,
                alternatives: bytes.alternatives
            )
            throw error
        }

        let mode = try await CloudKeyAuthorizationStore.shared
            .authorizeCurrentPrimaryKeyAfterValidation(rollbackTo: bytes)
        _ = mode
    }

    private func applyFreshCek(cek: Data) async throws {
        let bytes = try await snapshotCurrentKeys()
        do {
            try await EncryptionService.shared.setKeyBytes(cek)
        } catch {
            try EncryptionService.shared.replaceKeyBundle(
                primary: bytes.primary,
                alternatives: bytes.alternatives
            )
            throw error
        }
    }

    private func snapshotCurrentKeys() async throws -> CloudKeySnapshot {
        return EncryptionService.shared.getAllKeys()
    }

    private func ensureCurrentPrimaryKeyAuthorized() async -> Bool {
        if CloudKeyAuthorizationStore.shared.hasAuthorizedCurrentPrimaryKey() {
            return true
        }
        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
        guard validation.canWrite else { return false }
        return CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: .validated)
    }

    private func userInfo() -> PasskeyUserInfo? {
        guard let user = Clerk.shared.user else { return nil }
        let email = user.emailAddresses.first?.emailAddress ?? ""
        let displayName = [user.firstName, user.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return PasskeyUserInfo(
            userId: user.id,
            userEmail: email,
            displayName: displayName.isEmpty ? email : displayName
        )
    }

    private func persistEnclaveKeyState(keyIdHex: String, credentialId: String) {
        UserDefaults.standard.set(keyIdHex, forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId)
        UserDefaults.standard.set(credentialId, forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId)
    }

    private func cachedKeyIdHex() -> String? {
        UserDefaults.standard.string(forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId)
    }

    // MARK: - Periodic Sync Check

    /// Periodically calls `/v1/key/current` and detects when another
    /// device wiped + re-registered the user's key. When the keyId
    /// changes, the local CEK is invalidated and a fresh recovery
    /// flow is required.
    func startSyncCheck() {
        syncCheckTask?.cancel()
        syncCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.Passkey.syncCheckIntervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.refreshKeyFromEnclave()
            }
        }
    }

    private func refreshKeyFromEnclave() async {
        do {
            let state = try await SyncEnclaveAPI.keyCurrent()
            guard let remoteKeyId = state.keyId else { return }
            let storedKeyId = cachedKeyIdHex()
            if let storedKeyId, storedKeyId == remoteKeyId {
                return
            }

            // The keyId on the server changed — that only happens via
            // a `start_fresh` wipe. The local CEK is now stale; the
            // user must re-authenticate a passkey to unwrap the new
            // CEK. Surface this as a recovery prompt.
            if let credentialId = UserDefaults.standard.string(
                forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
            ),
               !state.bundles.values.contains(where: { $0.credentialId == credentialId }) {
                // Our credential is gone too — the only path forward
                // is a fresh recovery from another device.
                showPasskeyRecoveryChoice = true
                return
            }

            let result = await PasskeyKeyFlow.unlockFromServer(
                prefer: UserDefaults.standard.string(forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId)
            )
            if case .success(let cek, let keyIdHex, let credentialId, _) = result {
                do {
                    try await applyRecoveredCek(cek: cek)
                    persistEnclaveKeyState(keyIdHex: keyIdHex, credentialId: credentialId)
                    onKeyRefreshedFromBackup?()
                } catch {
                    showPasskeyRecoveryChoice = true
                }
            } else {
                showPasskeyRecoveryChoice = true
            }
        } catch {
            // Non-fatal — try again on the next tick.
        }
    }
}
