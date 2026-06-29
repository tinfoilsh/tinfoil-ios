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

// MARK: - KeyMismatchResolution

/// Outcome of reconciling a loaded local CEK against the enclave's
/// registered key at launch.
enum KeyMismatchResolution {
    case noMismatch
    case resolvedSilently
    case passkeyPromptShown
    case manualRecoveryRequired
}

// MARK: - PasskeyManager

@MainActor
final class PasskeyManager: ObservableObject {
    static let shared = PasskeyManager()

    // MARK: - Published State

    @Published var passkeyActive: Bool = false
    @Published var passkeySetupAvailable: Bool = false
    /// True when the user's key has bundle(s) on the enclave but
    /// none of them belong to this device's last-known credential id.
    /// Surfaces a "Set Up Passkey on This Device" prompt so the user
    /// can enroll a second authenticator (e.g. Touch ID after already
    /// having Windows Hello on another device).
    @Published var passkeyAddDeviceAvailable: Bool = false
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

    /// Remote keyId currently surfaced in the recovery-choice sheet,
    /// captured so a "Skip for Now" can record exactly which keyId the
    /// user dismissed.
    private var pendingRecoveryKeyId: String?

    /// True when the user skipped recovery for the current remote key
    /// and has not since regained a usable key. Mirrors the webapp's
    /// persistent recovery-dismissed flag and drives the Settings /
    /// sidebar "unlock cloud sync" affordances.
    @Published private(set) var recoverySkipped: Bool = false

    private init() {
        recoverySkipped = dismissedRecoveryKeyId != nil
    }

    /// Remote keyId the user explicitly skipped, persisted so the
    /// recovery sheet stays dismissed across app launches (matching the
    /// webapp). The periodic sync check must not re-surface the sheet
    /// for this keyId; a genuinely new keyId (another start_fresh) is
    /// not suppressed.
    private var dismissedRecoveryKeyId: String? {
        UserDefaults.standard.string(
            forKey: Constants.StorageKeys.Secret.passkeyRecoveryDismissedKeyId
        )
    }

    private func setDismissedRecoveryKeyId(_ keyId: String?) {
        if let keyId {
            UserDefaults.standard.set(
                keyId,
                forKey: Constants.StorageKeys.Secret.passkeyRecoveryDismissedKeyId
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: Constants.StorageKeys.Secret.passkeyRecoveryDismissedKeyId
            )
        }
        recoverySkipped = keyId != nil
    }

    // MARK: - Sign-Out Reset

    func reset() {
        passkeyActive = false
        passkeySetupAvailable = false
        passkeyAddDeviceAvailable = false
        showPasskeyRecoveryChoice = false
        pendingRecoveryKeyId = nil
        setDismissedRecoveryKeyId(nil)
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
            surfaceRecoveryChoice(forKeyId: nil)
            return .recoveryFailed
        }

        // When the enclave already has a usable v2 bundle, unlock
        // straight from the server. Use a silent ceremony so a device
        // that holds none of the registered bundles fails fast instead
        // of detouring through the cross-device QR sheet.
        if state.keyId != nil, !state.bundles.isEmpty {
            let serverResult = await PasskeyKeyFlow.unlockFromServer(silent: true)
            if case .success = serverResult {
                return await applyUnlockResult(serverResult)
            }
            // This device holds none of the registered bundles. Before
            // surfacing the recovery chooser, try this device's own
            // pre-enclave passkey: it unlocks the same CEK and enrolls
            // itself as a new bundle so future sessions use the v2 wire.
            let legacy = await LegacyPasskeyCredentials.fetch()
            if !legacy.isEmpty {
                let legacyResult = await PasskeyKeyFlow.recoverFromLegacyPasskey(
                    entries: legacy,
                    enclaveKeyId: state.keyId
                )
                if case .success = legacyResult {
                    return await applyUnlockResult(legacyResult)
                }
            }
            surfaceRecoveryChoice(forKeyId: state.keyId)
            return .recoveryFailed
        }

        // No usable v2 bundle. A brand-new user (no enclave key and no
        // remote data) gets the auto-generate flow. A legacy user whose
        // chats predate the key registry reports no key but has_data, so
        // exclude them here and let them fall through to recovery — a
        // fresh key would strand their un-migrated data.
        let remoteState = await CloudKeyPreflightValidator.shared.inspectRemoteState()
        if state.keyId == nil, !state.hasData, remoteState == .empty {
            let created = await attemptNewUserPasskeySetup()
            if !created {
                // No enclave key exists at all, so a leftover
                // "passkey active" flag from a prior session is stale.
                passkeyActive = false
                passkeySetupAvailable = true
            }
            return created ? .newUserSetupDone : .manualSetupRequired
        }

        // Remote data exists (or an enclave key exists with no bundle for
        // this device). Before any manual entry, try a passkey registered
        // on the pre-enclave webapp — that's still the primary recovery
        // path. Manual entry is only surfaced when no legacy passkey can
        // recover the CEK.
        let legacy = await LegacyPasskeyCredentials.fetch()
        if !legacy.isEmpty {
            let legacyResult = await PasskeyKeyFlow.recoverFromLegacyPasskey(
                entries: legacy,
                enclaveKeyId: state.keyId
            )
            switch legacyResult {
            case .success:
                return await applyUnlockResult(legacyResult)
            case .failure:
                // Fall through to manual recovery below.
                break
            }
        }

        passkeySetupAvailable = true
        return .manualRecoveryRequired
    }

    /// Reconcile a loaded local CEK that derives a different key id
    /// than the enclave's registered key. A stale device in that state
    /// can never write or migrate, so route it onto the registered key:
    /// try a silent passkey unlock first, surface the recovery-choice
    /// sheet when the key has bundles but the silent ceremony failed,
    /// and report `manualRecoveryRequired` when the key was adopted
    /// bundleless (e.g. by the migration path on another device) so the
    /// caller can open manual key entry. The replaced local key is kept
    /// in the key history, so the next migration sweep can still rewrap
    /// rows sealed under it.
    func resolveKeyMismatchAtLaunch() async -> KeyMismatchResolution {
        guard let cek = try? EncryptionService.shared.getKeyBytesOrThrow(),
              let localKeyId = try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek) else {
            return .noMismatch
        }
        guard let state = try? await SyncEnclaveAPI.keyCurrent(),
              let remoteKeyId = state.keyId,
              remoteKeyId != localKeyId else {
            return .noMismatch
        }

        guard !state.bundles.isEmpty else {
            return .manualRecoveryRequired
        }

        let result = await PasskeyKeyFlow.unlockFromServer(
            prefer: UserDefaults.standard.string(
                forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
            ),
            silent: true
        )
        if case .success(let recoveredCek, let keyIdHex, _, _) = result {
            do {
                try await applyRecoveredCek(cek: recoveredCek)
            } catch {
                surfaceRecoveryChoice(forKeyId: remoteKeyId)
                return .passkeyPromptShown
            }
            persistEnclaveKeyId(keyIdHex)
            activatePasskey()
            onKeyRefreshedFromBackup?()
            return .resolvedSilently
        }
        surfaceRecoveryChoice(forKeyId: remoteKeyId)
        return .passkeyPromptShown
    }

    /// Apply a successful passkey unlock/recovery result to local state,
    /// or surface a recovery failure. Shared by the v2 server-unlock and
    /// legacy-passkey recovery paths.
    private func applyUnlockResult(
        _ result: PasskeyFlowResult
    ) async -> PasskeyRecoveryResult {
        switch result {
        case .success(let cek, let keyIdHex, _, _):
            do {
                try await applyRecoveredCek(cek: cek)
            } catch {
                surfaceRecoveryChoice(forKeyId: keyIdHex)
                return .recoveryFailed
            }
            persistEnclaveKeyId(keyIdHex)
            activatePasskey()
            return .success
        case .failure:
            surfaceRecoveryChoice(forKeyId: nil)
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
        case .success(let cek, let keyIdHex, _, _):
            do {
                try await applyFreshCek(cek: cek)
                guard CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: authorizationMode) else {
                    EncryptionService.shared.clearKey()
                    throw CloudKeyAuthorizationError.authorizationUnavailable
                }
                persistEnclaveKeyId(keyIdHex)
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

    // MARK: - Recovery Choice Presentation

    /// Surface the recovery-choice sheet for a given remote keyId,
    /// unless the user already skipped recovery for that same keyId.
    /// Records the keyId so a later Skip can suppress re-prompting.
    private func surfaceRecoveryChoice(forKeyId keyId: String?) {
        if let keyId, keyId == dismissedRecoveryKeyId {
            return
        }
        pendingRecoveryKeyId = keyId
        showPasskeyRecoveryChoice = true
    }

    /// Dismiss the recovery-choice sheet and remember which keyId the
    /// user skipped so the periodic sync check stops re-presenting it.
    func dismissRecoveryChoice() {
        // Only persist a concrete keyId. Skipping a sheet with no pending
        // keyId must not clear an existing skip, or the periodic check
        // would re-present recovery for a keyId the user already skipped.
        if let keyId = pendingRecoveryKeyId {
            setDismissedRecoveryKeyId(keyId)
        }
        showPasskeyRecoveryChoice = false
    }

    /// Clear a persisted recovery skip and re-run the recovery decision
    /// tree. Backs the Settings and sidebar "unlock cloud sync"
    /// affordances so a user who previously skipped can re-open
    /// recovery. Mirrors the webapp's `showPasskeyRecoveryPrompt`.
    /// Returns the recovery result so the caller can route the manual
    /// setup / recovery cases to the onboarding sheet.
    func reenableRecoveryPrompt() async -> PasskeyRecoveryResult {
        pendingRecoveryKeyId = nil
        setDismissedRecoveryKeyId(nil)
        guard EncryptionService.shared.hasEncryptionKey() else {
            return await attemptPasskeyKeyRecovery()
        }
        // A local key is present but it may be stale (rotated away by a
        // `start_fresh` on another device). Re-run the mismatch resolver
        // so a stale device re-enters recovery instead of being treated
        // as already unlocked.
        switch await resolveKeyMismatchAtLaunch() {
        case .manualRecoveryRequired:
            return .manualRecoveryRequired
        case .noMismatch:
            await checkPasskeyStateForExistingKey()
            return .success
        case .resolvedSilently, .passkeyPromptShown:
            return .success
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
        case .success(let cek, let keyIdHex, _, _):
            do {
                try await applyRecoveredCek(cek: cek)
            } catch {
                return false
            }
            persistEnclaveKeyId(keyIdHex)
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
            if let remoteKeyId = state.keyId, !state.bundles.isEmpty {
                // Derive the local key id so we can tell whether this
                // device is actually on the current key or is holding a
                // stale CEK that a `start_fresh` elsewhere rotated away.
                let localKeyId: String? = {
                    guard let cek = try? EncryptionService.shared.getKeyBytesOrThrow() else {
                        return nil
                    }
                    return try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
                }()
                let isOnCurrentKey = localKeyId == remoteKeyId

                if isOnCurrentKey {
                    // The device is genuinely on the current key, so the
                    // user is no longer in a locked/skipped state. Drop
                    // any persisted recovery skip (e.g. left over from a
                    // manual unlock that bypassed the passkey flow). A
                    // stale device keeps its skip so it stays suppressed.
                    setDismissedRecoveryKeyId(nil)
                    // Persist the keyId now so the periodic sync check has
                    // a baseline. Without this, a normal app launch (with
                    // a valid local CEK that matches the remote) would
                    // look like a `start_fresh` rotation on the next
                    // refresh tick and force the user through recovery.
                    if cachedKeyIdHex() == nil {
                        UserDefaults.standard.set(
                            remoteKeyId,
                            forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId
                        )
                    }
                }

                // The bundle map is keyed by credential id. If this
                // device's last-known credential id is among the
                // bundles, the device has its own backup and we can
                // light up the "passkey active" UI. Otherwise the
                // user has bundles on *other* devices but none here
                // yet — surface the add-this-device prompt instead.
                let localCredentialId = UserDefaults.standard.string(
                    forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
                )
                let hasBundleForThisDevice = localCredentialId.flatMap { id in
                    state.bundles.values.contains { $0.credentialId == id }
                } ?? false

                if hasBundleForThisDevice {
                    passkeyActive = true
                    passkeyAddDeviceAvailable = false
                    passkeySetupAvailable = false
                } else {
                    passkeyActive = false
                    passkeyAddDeviceAvailable = true
                    passkeySetupAvailable = false
                }
                startSyncCheck()
                return
            }
            // The enclave definitively reports no registered key or no
            // bundles at all, so any previously lit "passkey active"
            // state is stale and must not survive the transition.
            passkeyActive = false
        } catch {
            // fall through to "setup available"
        }
        passkeySetupAvailable = true
        passkeyAddDeviceAvailable = false
    }

    /// Re-evaluate per-device bundle state without prompting any
    /// passkey UI. Safe to call any time the enclave's bundle map
    /// may have changed (e.g. legacy-blob migration completed,
    /// another device just added a bundle).
    func refreshBundleState() async {
        guard EncryptionService.shared.hasEncryptionKey() else { return }
        await checkPasskeyStateForExistingKey()
    }

    /// Fetch the enclave's bundle inventory for the current key. Used
    /// by the Settings "Registered platforms" list so the view never
    /// talks to the enclave wire directly.
    func listPasskeyBundles() async throws -> [EnclaveKeyCurrentBundle] {
        let state = try await SyncEnclaveAPI.keyCurrent()
        return Array(state.bundles.values)
    }

    /// Remove a passkey bundle from the enclave's current key, then
    /// re-evaluate the local passkey state.
    func removePasskeyBundle(credentialId: String) async throws {
        let cek = try EncryptionService.shared.getKeyBytesOrThrow()
        let keyIdHex = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        try await PasskeyKeyFlow.removeBundleFromCurrentKey(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: credentialId
        )
        await refreshBundleState()
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
                if case .success = result {
                    persistEnclaveKeyId(keyIdHex)
                    activatePasskey()
                    // Adopting the existing CEK just registered it as
                    // the current key, so the migration gate that the
                    // launch-time pass tripped over now clears. Re-seal
                    // any legacy rows now instead of waiting for the
                    // next launch.
                    Task.detached(priority: .background) {
                        _ = await LegacyBlobMigration.runAndFinalize()
                        await PasskeyManager.shared.refreshBundleState()
                    }
                }
                return
            }

            // Existing key — enroll a new passkey for it.
            let result = await PasskeyKeyFlow.addBundleForCurrentKey(
                cek: cek,
                keyIdHex: keyIdHex,
                user: user
            )
            if case .success = result {
                persistEnclaveKeyId(keyIdHex)
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
        passkeyAddDeviceAvailable = false
        passkeySetupAvailable = false
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

    /// The enclave key_id is the SHA-256 of the local CEK — it's
    /// safe to cache locally and lets the periodic sync check
    /// detect a remote `start_fresh` rotation. The credential id is
    /// persisted separately by `PasskeyService` after a successful
    /// WebAuthn ceremony, gated on `.platform` attachment.
    private func persistEnclaveKeyId(_ keyIdHex: String) {
        UserDefaults.standard.set(keyIdHex, forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId)
        // A successful unlock clears any prior skip so a future genuine
        // mismatch can prompt again.
        pendingRecoveryKeyId = nil
        setDismissedRecoveryKeyId(nil)
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
                surfaceRecoveryChoice(forKeyId: remoteKeyId)
                return
            }

            // Silent ceremony only: this runs from the background sync
            // loop, which must never pop interactive system passkey UI.
            let result = await PasskeyKeyFlow.unlockFromServer(
                prefer: UserDefaults.standard.string(forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId),
                silent: true
            )
            switch result {
            case .success(let cek, let keyIdHex, _, _):
                do {
                    try await applyRecoveredCek(cek: cek)
                    persistEnclaveKeyId(keyIdHex)
                    onKeyRefreshedFromBackup?()
                } catch {
                    surfaceRecoveryChoice(forKeyId: remoteKeyId)
                }
            case .failure(.enclaveUnavailable, _):
                // Transient enclave/network failure — the keyId is
                // still mismatched, so the next tick retries the
                // refresh instead of jumping straight to the
                // recovery / start-fresh prompt.
                break
            case .failure:
                surfaceRecoveryChoice(forKeyId: remoteKeyId)
            }
        } catch {
            // Non-fatal — try again on the next tick.
        }
    }
}
