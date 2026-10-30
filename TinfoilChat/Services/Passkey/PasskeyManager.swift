//
//  PasskeyManager.swift
//  TinfoilChat
//
//  Manages passkey lifecycle on top of the chat service's
//  key registry (/v1/keys/*). Mirrors the webapp's `usePasskeyBackup`
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
    case temporarilyUnavailable
    case setupFailed(PasskeyFlowFailure)
    case recoveryFailed
}

enum PasskeyBackupResult: Sendable {
    case success
    case failure(PasskeyFlowFailure)
}

struct PasskeySetupFailurePresentation: Equatable, Sendable {
    let title: String
    let message: String

    static let authenticationFailed = PasskeySetupFailurePresentation(
        title: "Passkey Authentication Failed",
        message: "You can try again or enter your encryption key manually."
    )

    private init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ failure: PasskeyFlowFailure) {
        switch failure {
        case .prfUnsupported:
            title = "Passkey Provider Not Supported"
            message = "Your passkey provider doesn't support the security features required by Tinfoil. Try another passkey provider and try again."
        case .timedOut:
            title = "Passkey Setup Timed Out"
            message = "The passkey operation timed out. Please try again."
        case .presentationUnavailable:
            title = "Passkey Setup Unavailable"
            message = "Tinfoil couldn't open the passkey prompt. Return to the app and try again."
        case .enclaveUnavailable:
            title = "Cloud Sync Temporarily Unavailable"
            message = "Check your connection and try setting up your passkey again."
        case .userCancelled:
            title = "Passkey Setup Canceled"
            message = "Passkey setup was canceled. Try again when you're ready."
        case .noRemoteBundle, .noRemoteKey, .bundleDecryptFailed, .registerFailed, .remoteKeyExists, .keyIdMismatch:
            title = "Couldn't Enable Cloud Sync"
            message = "Passkey setup failed. Please try again."
        }
    }
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

enum PasskeyBundleInventoryVerification: Equatable {
    case match
    case mismatch
    case unverified
}

struct PasskeyBundleInventory {
    let bundles: [KeyState.Bundle]
    let verification: PasskeyBundleInventoryVerification

    func preservingBundlesAsUnverified() -> PasskeyBundleInventory {
        PasskeyBundleInventory(
            bundles: bundles,
            verification: .unverified
        )
    }
}

enum PasskeyBundleRemovalOutcome: Equatable {
    case removed
    case alreadyMissing
}

struct PasskeyBundleRemovalResult {
    let outcome: PasskeyBundleRemovalOutcome
    let inventory: PasskeyBundleInventory
}

enum PasskeyBundleRemovalError: Error, Equatable {
    case missing
    case keyMismatch
    case unverifiable
    case authentication
    case server
}

enum PasskeyBundleRemovalDecision: Equatable {
    case remove
    case alreadyMissing
    case reject(PasskeyBundleRemovalError)
}

struct PasskeyBundleAvailability: Equatable {
    let active: Bool
    let setupAvailable: Bool
    let addDeviceAvailable: Bool
    let keyMatches: Bool
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

    /// Called when the periodic key check detects that another
    /// device started fresh and applied a new CEK to the enclave's
    /// key registry. The consumer should retry decryption of failed
    /// chats.
    var onKeyRefreshedFromBackup: (() -> Void)?

    // MARK: - Private

    private var syncCheckTask: Task<Void, Never>?
    private var accountOperationsEnabled = true
    private var accountGeneration = 0
    private let accountOperationTracker = AccountOperationTracker()
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
    /// webapp). The periodic key check must not re-surface the sheet
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

    func reset() async {
        accountOperationsEnabled = false
        accountGeneration &+= 1
        await accountOperationTracker.closeAndWait()
        let canceledSyncCheckTask = syncCheckTask
        canceledSyncCheckTask?.cancel()
        syncCheckTask = nil
        await canceledSyncCheckTask?.value

        passkeyActive = false
        passkeySetupAvailable = false
        passkeyAddDeviceAvailable = false
        showPasskeyRecoveryChoice = false
        pendingRecoveryKeyId = nil
        setDismissedRecoveryKeyId(nil)
        onRecoveryComplete = nil
        onKeyRefreshedFromBackup = nil
        passkeyService.clearLocalCredential()
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId)
    }

    func resumeAccountOperations() {
        accountOperationsEnabled = true
        accountOperationTracker.reopen()
    }

    // MARK: - Recovery Flow

    /// Attempt to recover encryption keys via passkey, or auto-generate for new users.
    func attemptPasskeyKeyRecovery() async -> PasskeyRecoveryResult {
        let state: KeyState
        do {
            state = try await KeyRegistry.shared.current()
        } catch {
            PasskeyDiagnostics.failure(
                "attemptRecovery: keyCurrent failed: \(PasskeyDiagnostics.describe(error))"
            )
            return canMutateAccountKey ? .temporarilyUnavailable : .recoveryFailed
        }
        guard canMutateAccountKey else { return .recoveryFailed }

        let candidates = PasskeyRecoveryCandidates(
            bundles: Array(state.bundles.values),
            preferredCredentialId: localCredentialId
        )

        if !candidates.credentialIds.isEmpty {
            guard let recoveryAccount = recoveryAccountSnapshot() else {
                PasskeyDiagnostics.failure("attemptRecovery: no account snapshot (signed out?)")
                return .recoveryFailed
            }
            let result = await PasskeyKeyFlow.recoverFromRegistry(
                state: state,
                prefer: localCredentialId,
                immediatelyAvailable: true
            )
            guard canMutateAccountKey else { return .recoveryFailed }
            switch result {
            case .current(let current, let legacyAlternatives):
                if await applyValidatedCurrentRecovery(
                    current,
                    legacyAlternatives: legacyAlternatives,
                    expectedAccount: recoveryAccount
                ) {
                    PasskeyDiagnostics.step("attemptRecovery: silent recovery succeeded")
                    return .success
                }
                PasskeyDiagnostics.failure("attemptRecovery: recovered key failed validation")
            case .failure(let failure, let message):
                PasskeyDiagnostics.failure(
                    "attemptRecovery: silent ceremony failed (\(failure.rawValue)): \(message ?? "-")"
                )
            }
            surfaceRecoveryChoice(forKeyId: state.keyId)
            return .recoveryFailed
        }

        // No usable v2 bundle. A brand-new user (no enclave key and no
        // remote data) gets the auto-generate flow. A legacy user whose
        // chats predate the key registry reports no key but has_data, so
        // exclude them here and let them fall through to recovery — a
        // fresh key would strand their un-migrated data.
        guard canMutateAccountKey else { return .recoveryFailed }
        if state.keyId == nil, !state.hasData {
            // The registry is read again right before a fresh key is
            // registered: data or a key another device stored meanwhile
            // must not be stranded.
            let current: KeyState
            do {
                current = try await KeyRegistry.shared.current()
            } catch {
                PasskeyDiagnostics.failure(
                    "attemptRecovery: keyCurrent failed before setup: \(PasskeyDiagnostics.describe(error))"
                )
                return canMutateAccountKey ? .temporarilyUnavailable : .recoveryFailed
            }
            guard canMutateAccountKey else { return .recoveryFailed }
            guard current.keyId == nil, !current.hasData else {
                PasskeyDiagnostics.failure("attemptRecovery: the account gained a key or data during setup")
                passkeySetupAvailable = true
                return .manualRecoveryRequired
            }
            let result = await attemptNewUserPasskeySetup()
            if case .failure = result {
                // No enclave key exists at all, so a leftover
                // "passkey active" flag from a prior session is stale.
                passkeyActive = false
                passkeySetupAvailable = true
            }
            switch result {
            case .success:
                return .newUserSetupDone
            case .failure(let failure):
                return .setupFailed(failure)
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
              let localKeyId = try? ContentKeyBundle.deriveKeyIdHex(cek: cek) else {
            return .noMismatch
        }
        guard let state = try? await KeyRegistry.shared.current(),
              let remoteKeyId = state.keyId,
              remoteKeyId != localKeyId else {
            return .noMismatch
        }
        guard canMutateAccountKey else { return .noMismatch }
        PasskeyDiagnostics.step(
            "launchMismatch: local=\(PasskeyDiagnostics.keyIdPrefix(localKeyId)) "
            + "remote=\(PasskeyDiagnostics.keyIdPrefix(remoteKeyId)) bundles=\(state.bundles.count)"
        )

        guard !state.bundles.isEmpty else {
            PasskeyDiagnostics.failure("launchMismatch: remote key has no bundles, manual recovery required")
            return .manualRecoveryRequired
        }

        let result = await PasskeyKeyFlow.unlockFromServer(
            prefer: UserDefaults.standard.string(
                forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
            ),
            silent: true
        )
        guard canMutateAccountKey else { return .noMismatch }
        if case .success(let recoveredCek, let keyIdHex, _, _) = result {
            do {
                try await applyRecoveredCek(cek: recoveredCek)
            } catch {
                guard canMutateAccountKey else { return .noMismatch }
                surfaceRecoveryChoice(forKeyId: remoteKeyId)
                return .passkeyPromptShown
            }
            guard canMutateAccountKey else { return .noMismatch }
            persistEnclaveKeyId(keyIdHex)
            activatePasskey()
            onKeyRefreshedFromBackup?()
            return .resolvedSilently
        }
        surfaceRecoveryChoice(forKeyId: remoteKeyId)
        return .passkeyPromptShown
    }

    private func applyValidatedCurrentRecovery(
        _ result: PasskeyFlowResult,
        legacyAlternatives: [String],
        expectedAccount: RecoveryAccountSnapshot
    ) async -> Bool {
        guard case .success(let cek, let keyIdHex, let credentialId, _) = result else {
            return false
        }
        guard let currentState = try? await KeyRegistry.shared.current(),
              canMutateAccountKey,
              Self.canApplyCurrentRecovery(
                  recoveredKeyId: keyIdHex,
                  credentialId: credentialId,
                  currentState: currentState,
                  expectedAccount: expectedAccount,
                  currentUserId: Clerk.shared.user?.id,
                  currentGeneration: accountGeneration
              ) else {
            PasskeyDiagnostics.failure(
                "applyRecovery: post-unlock validation failed "
                + "(key rotated mid-flight, credential removed, or account changed)"
            )
            return false
        }
        do {
            try await applyRecoveredCek(cek: cek)
        } catch {
            PasskeyDiagnostics.failure(
                "applyRecovery: applying recovered key failed: \(PasskeyDiagnostics.describe(error))"
            )
            return false
        }
        guard canMutateAccountKey,
              Self.isExpectedRecoveryAccount(
                  expectedAccount,
                  currentUserId: Clerk.shared.user?.id,
                  currentGeneration: accountGeneration
              ) else {
            PasskeyDiagnostics.failure("applyRecovery: account changed while applying key")
            return false
        }
        PasskeyKeyFlow.retainLegacyAlternatives(legacyAlternatives)
        persistEnclaveKeyId(keyIdHex)
        activatePasskey()
        return true
    }

    /// Auto-generate a key and create a passkey for a brand new user.
    @discardableResult
    private func attemptNewUserPasskeySetup(
        createdVia: KeyOrigin = .passkey
    ) async -> PasskeyBackupResult {
        guard let user = userInfo() else { return .failure(.registerFailed) }

        let result = await PasskeyKeyFlow.registerNewKeyWithPasskey(
            user: user,
            createdVia: createdVia
        )
        guard canMutateAccountKey else { return .failure(.userCancelled) }
        switch result {
        case .success(let cek, let keyIdHex, _, _):
            do {
                try await applyFreshCek(cek: cek, discardingHistory: createdVia == .startFresh)
                guard canMutateAccountKey else { throw CancellationError() }
                persistEnclaveKeyId(keyIdHex)
                activatePasskey()
                return .success
            } catch {
                #if DEBUG
                print("[PasskeyManager] applyFreshCek failed: \(error)")
                #endif
                return .failure(.registerFailed)
            }
        case .failure(let reason, _):
            #if DEBUG
            print("[PasskeyManager] registerNewKeyWithPasskey failed: \(reason)")
            #endif
            return .failure(reason)
        }
    }

    // MARK: - Recovery Choice Presentation

    /// Surface the recovery-choice sheet for a given remote keyId,
    /// unless the user already skipped recovery for that same keyId.
    /// Records the keyId so a later Skip can suppress re-prompting.
    private func surfaceRecoveryChoice(forKeyId keyId: String?) {
        if let keyId, keyId == dismissedRecoveryKeyId {
            PasskeyDiagnostics.warn(
                "recoveryChoice: suppressed, user previously skipped keyId=\(PasskeyDiagnostics.keyIdPrefix(keyId))"
            )
            return
        }
        PasskeyDiagnostics.step(
            "recoveryChoice: presenting sheet for keyId=\(PasskeyDiagnostics.keyIdPrefix(keyId))"
        )
        pendingRecoveryKeyId = keyId
        showPasskeyRecoveryChoice = true
    }

    /// Dismiss the recovery-choice sheet and remember which keyId the
    /// user skipped so the periodic key check stops re-presenting it.
    func dismissRecoveryChoice() {
        // Only persist a concrete keyId. Skipping a sheet with no pending
        // keyId must not clear an existing skip, or the periodic check
        // would re-present recovery for a keyId the user already skipped.
        if let keyId = pendingRecoveryKeyId {
            setDismissedRecoveryKeyId(keyId)
        }
        pendingRecoveryKeyId = nil
        showPasskeyRecoveryChoice = false
    }

    func beginManualKeyRecovery() {
        pendingRecoveryKeyId = nil
        showPasskeyRecoveryChoice = false
    }

    func recoveryChoiceDidDismiss() {
        if let keyId = pendingRecoveryKeyId {
            setDismissedRecoveryKeyId(keyId)
        }
        pendingRecoveryKeyId = nil
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
        case .resolvedSilently:
            return .success
        case .passkeyPromptShown:
            return .recoveryFailed
        }
    }

    // MARK: - Recovery Choice Actions

    func retryPasskeyRecovery() async -> Bool {
        let state: KeyState
        do {
            state = try await KeyRegistry.shared.current()
        } catch {
            PasskeyDiagnostics.failure(
                "retryRecovery: keyCurrent failed: \(PasskeyDiagnostics.describe(error))"
            )
            return false
        }
        guard canMutateAccountKey else { return false }
        let candidates = PasskeyRecoveryCandidates(
            bundles: Array(state.bundles.values),
            preferredCredentialId: localCredentialId
        )
        guard !candidates.credentialIds.isEmpty,
              let recoveryAccount = recoveryAccountSnapshot() else {
            PasskeyDiagnostics.failure(
                "retryRecovery: no candidates (bundles=\(state.bundles.count)) or no account"
            )
            return false
        }
        let result = await PasskeyKeyFlow.recoverFromRegistry(
            state: state,
            prefer: localCredentialId,
            immediatelyAvailable: false
        )
        guard canMutateAccountKey else { return false }
        switch result {
        case .current(let current, let legacyAlternatives):
            guard await applyValidatedCurrentRecovery(
                current,
                legacyAlternatives: legacyAlternatives,
                expectedAccount: recoveryAccount
            ) else {
                PasskeyDiagnostics.report("retryRecovery: recovered key failed validation")
                return false
            }
            PasskeyDiagnostics.step("retryRecovery: interactive recovery succeeded")
            return Self.finishRecoveryRetry(
                appliedResult: .success,
                isCurrentAccount: canMutateAccountKey,
                dismiss: { self.showPasskeyRecoveryChoice = false },
                resume: { Self.takeRecoveryCompletion(&self.onRecoveryComplete)?() }
            )
        case .failure(let failure, let message):
            // A user-cancelled prompt is a normal outcome, not an error
            // worth a Sentry event; keep it as a breadcrumb only.
            if failure == .userCancelled {
                PasskeyDiagnostics.step("retryRecovery: interactive ceremony cancelled by user")
            } else {
                PasskeyDiagnostics.report(
                    "retryRecovery: interactive ceremony failed (\(failure.rawValue)): \(message ?? "-")"
                )
            }
            return false
        }
    }

    func startFreshWithNewKey() async -> PasskeyBackupResult {
        let result = await attemptNewUserPasskeySetup(createdVia: .startFresh)
        if case .success = result {
            showPasskeyRecoveryChoice = false
            Self.takeRecoveryCompletion(&onRecoveryComplete)?()
        }
        return result
    }

    // MARK: - Setup & Backup

    /// Retry passkey setup. When an encryption key already exists,
    /// adds a new passkey bundle for the current CEK. When no key
    /// exists, runs the new-user flow that generates a key and
    /// registers it server-side in one step.
    func retryPasskeySetup() async -> PasskeyRecoveryResult {
        if EncryptionService.shared.hasEncryptionKey() {
            guard await ensureCurrentPrimaryKeyAuthorized() else {
                PasskeyDiagnostics.failure("retrySetup: local key not authorized for cloud writes")
                passkeySetupAvailable = true
                return .manualRecoveryRequired
            }
            switch await createPasskeyBackup() {
            case .success:
                return .success
            case .failure(.enclaveUnavailable):
                PasskeyDiagnostics.failure("retrySetup: enclave unavailable")
                return .temporarilyUnavailable
            case .failure(let failure):
                PasskeyDiagnostics.failure("retrySetup: backup failed (\(failure.rawValue))")
                return .setupFailed(failure)
            }
        }
        PasskeyDiagnostics.step("retrySetup: no local key, falling through to recovery")
        // An explicit user request to enable sync overrides a stale
        // "Skip for Now": if the silent ceremony fails, the recovery
        // choice sheet must be allowed to appear so the user can run
        // an interactive unlock instead of dead-ending on a generic
        // failure alert.
        pendingRecoveryKeyId = nil
        setDismissedRecoveryKeyId(nil)
        return await attemptPasskeyKeyRecovery()
    }

    /// Check passkey state for users who already have keys loaded.
    func checkPasskeyStateForExistingKey(preserveStateOnFailure: Bool = false) async {
        do {
            let state = try await KeyRegistry.shared.current()
            guard canMutateAccountKey else { return }
            applyPasskeyAvailability(
                state: state,
                localKeyId: localKeyIdHex()
            )
        } catch {
            guard canMutateAccountKey else { return }
            guard !preserveStateOnFailure else { return }
            passkeyActive = false
            passkeySetupAvailable = false
            passkeyAddDeviceAvailable = false
        }
    }

    /// Re-evaluate per-device bundle state without prompting any
    /// passkey UI. Safe to call any time the enclave's bundle map
    /// may have changed (e.g. legacy-blob migration completed,
    /// another device just added a bundle).
    func refreshBundleState() async {
        guard accountOperationsEnabled else { return }
        guard EncryptionService.shared.hasEncryptionKey() else { return }
        await checkPasskeyStateForExistingKey()
    }

    /// Fetch one enclave snapshot and verify it against the local CEK.
    /// Used by Settings so stale inventory can remain visible without
    /// being actionable when the current state cannot be verified.
    func passkeyBundleInventory() async throws -> PasskeyBundleInventory {
        let state: KeyState = try await KeyRegistry.shared.current()
        let localKeyId: String? = localKeyIdHex()
        return Self.passkeyBundleInventory(
            state: state,
            localKeyId: localKeyId
        )
    }

    /// Remove a passkey bundle from the enclave's current key, then
    /// re-evaluate the local passkey state.
    func removePasskeyBundle(credentialId: String) async throws -> PasskeyBundleRemovalResult {
        guard accountOperationsEnabled else { throw CancellationError() }
        let operationTask: Task<PasskeyBundleRemovalResult, Error> = Task {
            try Task.checkCancellation()
            let currentState: KeyState
            do {
                currentState = try await KeyRegistry.shared.current()
            } catch {
                if error is CancellationError { throw error }
                throw Self.passkeyBundleRemovalError(from: error)
            }
            try Task.checkCancellation()
            guard accountOperationsEnabled else { throw CancellationError() }

            guard currentState.bundles.values.contains(where: { $0.credentialId == credentialId }) else {
                let localKeyId: String? = localKeyIdHex()
                applyPasskeyAvailability(
                    state: currentState,
                    localKeyId: localKeyId
                )
                let result = PasskeyBundleRemovalResult(
                    outcome: .alreadyMissing,
                    inventory: Self.passkeyBundleInventory(
                        state: currentState,
                        localKeyId: localKeyId
                    )
                )
                await checkPasskeyStateForExistingKey(preserveStateOnFailure: true)
                return result
            }

            let cek: Data
            let keyIdHex: String
            do {
                cek = try EncryptionService.shared.getKeyBytesOrThrow()
                keyIdHex = try ContentKeyBundle.deriveKeyIdHex(cek: cek)
            } catch {
                throw PasskeyBundleRemovalError.unverifiable
            }

            switch Self.passkeyBundleRemovalDecision(
                credentialId: credentialId,
                state: currentState,
                localKeyId: keyIdHex
            ) {
            case .remove:
                break
            case .alreadyMissing:
                applyPasskeyAvailability(
                    state: currentState,
                    localKeyId: keyIdHex
                )
                let result = PasskeyBundleRemovalResult(
                    outcome: .alreadyMissing,
                    inventory: Self.passkeyBundleInventory(
                        state: currentState,
                        localKeyId: keyIdHex
                    )
                )
                await checkPasskeyStateForExistingKey(preserveStateOnFailure: true)
                return result
            case .reject(let error):
                throw error
            }

            let outcome: PasskeyBundleRemovalOutcome
            do {
                try await PasskeyKeyFlow.removeBundleFromCurrentKey(
                    cek: cek,
                    keyIdHex: keyIdHex,
                    credentialId: credentialId
                )
                outcome = .removed
            } catch {
                if error is CancellationError { throw error }
                let removalError = Self.passkeyBundleRemovalError(from: error)
                guard removalError == .missing else { throw removalError }
                outcome = .alreadyMissing
            }
            try Task.checkCancellation()
            guard accountOperationsEnabled else { throw CancellationError() }
            let updatedState = Self.removingPasskeyBundle(
                credentialId: credentialId,
                from: currentState
            )
            applyPasskeyAvailability(
                state: updatedState,
                localKeyId: keyIdHex
            )
            let result = PasskeyBundleRemovalResult(
                outcome: outcome,
                inventory: Self.passkeyBundleInventory(
                    state: updatedState,
                    localKeyId: keyIdHex
                )
            )
            return result
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            throw CancellationError()
        }
        defer { accountOperationTracker.end(operationToken) }

        return try await operationTask.value
    }

    /// Create a passkey bundle for the user's existing CEK. Used by
    /// "Add this device to passkey backup" in Settings.
    func createPasskeyBackup() async -> PasskeyBackupResult {
        guard canMutateAccountKey else { return .failure(.userCancelled) }
        guard let user = userInfo() else { return .failure(.registerFailed) }
        guard await ensureCurrentPrimaryKeyAuthorized() else { return .failure(.registerFailed) }
        guard canMutateAccountKey else { return .failure(.userCancelled) }
        let cek: Data
        do {
            cek = try EncryptionService.shared.getKeyBytesOrThrow()
        } catch {
            return .failure(.registerFailed)
        }
        let keyIdHex: String
        do {
            keyIdHex = try ContentKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return .failure(.registerFailed)
        }

        // Determine whether to register-key or add-bundle by probing
        // the enclave first. A 404 / nil key_id means "first time
        // ever", in which case we register the existing local CEK
        // with an initial bundle — never generate a fresh CEK here,
        // or we'd silently strand every local chat sealed under the
        // existing key.
        do {
            let state = try await KeyRegistry.shared.current()
            guard canMutateAccountKey else { return .failure(.userCancelled) }
            if state.keyId == nil {
                let result = await PasskeyKeyFlow.registerExistingKeyWithPasskey(
                    existingCek: cek,
                    user: user,
                    createdVia: .recovery
                )
                guard canMutateAccountKey else { return .failure(.userCancelled) }
                switch result {
                case .success:
                    persistEnclaveKeyId(keyIdHex)
                    activatePasskey()
                    return .success
                case .failure(let failure, _):
                    return .failure(failure)
                }
            }

            // Existing key — enroll a new passkey for it.
            let result = await PasskeyKeyFlow.addBundleForCurrentKey(
                cek: cek,
                keyIdHex: keyIdHex,
                user: user
            )
            guard canMutateAccountKey else { return .failure(.userCancelled) }
            switch result {
            case .success:
                persistEnclaveKeyId(keyIdHex)
                activatePasskey()
                return .success
            case .failure(let failure, _):
                return .failure(failure)
            }
        } catch let error as HarnessError {
            // Leave state unchanged while preserving the service failure category.
            return .failure(PasskeyKeyFlow.failureFromRegistryError(error))
        } catch {
            return .failure(.enclaveUnavailable)
        }
    }

    // MARK: - Private Helpers

    private func activatePasskey() {
        SettingsManager.shared.isCloudSyncEnabled = true
        passkeyActive = true
        passkeyAddDeviceAvailable = false
        passkeySetupAvailable = false
        startSyncCheck()
    }

    static func passkeyBundleInventory(
        state: KeyState,
        localKeyId: String?
    ) -> PasskeyBundleInventory {
        let verification: PasskeyBundleInventoryVerification = {
            if let localKeyId, let remoteKeyId = state.keyId {
                return localKeyId == remoteKeyId ? .match : .mismatch
            }
            return .unverified
        }()
        return PasskeyBundleInventory(
            bundles: Array(state.bundles.values),
            verification: verification
        )
    }

    static func passkeyBundleRemovalDecision(
        credentialId: String,
        state: KeyState,
        localKeyId: String?
    ) -> PasskeyBundleRemovalDecision {
        guard state.bundles.values.contains(where: { $0.credentialId == credentialId }) else {
            return .alreadyMissing
        }
        guard let localKeyId, let remoteKeyId = state.keyId else {
            return .reject(.unverifiable)
        }
        guard localKeyId == remoteKeyId else {
            return .reject(.keyMismatch)
        }
        return .remove
    }

    static func passkeyBundleAvailability(
        state: KeyState,
        localKeyId: String?,
        localCredentialId: String? = nil
    ) -> PasskeyBundleAvailability {
        guard let remoteKeyId = state.keyId else {
            return PasskeyBundleAvailability(
                active: false,
                setupAvailable: true,
                addDeviceAvailable: false,
                keyMatches: false
            )
        }
        guard let localKeyId, localKeyId == remoteKeyId else {
            return PasskeyBundleAvailability(
                active: false,
                setupAvailable: false,
                addDeviceAvailable: false,
                keyMatches: false
            )
        }
        guard !state.bundles.isEmpty else {
            return PasskeyBundleAvailability(
                active: false,
                setupAvailable: true,
                addDeviceAvailable: false,
                keyMatches: true
            )
        }
        let hasLocalBundle = localCredentialId.map { credentialId in
            state.bundles.values.contains { $0.credentialId == credentialId }
        } ?? false
        return PasskeyBundleAvailability(
            active: hasLocalBundle,
            setupAvailable: false,
            addDeviceAvailable: !hasLocalBundle,
            keyMatches: true
        )
    }

    static func removingPasskeyBundle(
        credentialId: String,
        from state: KeyState
    ) -> KeyState {
        KeyState(
            keyId: state.keyId,
            etag: state.etag,
            bundles: state.bundles.filter { $0.value.credentialId != credentialId },
            createdVia: state.createdVia,
            createdAt: state.createdAt,
            hasData: state.hasData
        )
    }

    static func passkeyBundleRemovalError(from error: Error) -> PasskeyBundleRemovalError {
        guard let registryError = error as? HarnessError else { return .server }
        if registryError.code == HarnessErrorCode.unauthenticated || registryError.action == .reauthenticate {
            return .authentication
        }
        if registryError.isKeyMismatch {
            return .keyMismatch
        }
        if registryError.status == Constants.Harness.Keys.notFoundStatus {
            return .missing
        }
        return .server
    }

    private func localKeyIdHex() -> String? {
        guard let cek = try? EncryptionService.shared.getKeyBytesOrThrow() else { return nil }
        return try? ContentKeyBundle.deriveKeyIdHex(cek: cek)
    }

    private var localCredentialId: String? {
        UserDefaults.standard.string(
            forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
        )
    }

    private func applyPasskeyAvailability(
        state: KeyState,
        localKeyId: String?
    ) {
        let availability = Self.passkeyBundleAvailability(
            state: state,
            localKeyId: localKeyId,
            localCredentialId: localCredentialId
        )
        passkeyActive = availability.active
        passkeySetupAvailable = availability.setupAvailable
        passkeyAddDeviceAvailable = availability.addDeviceAvailable

        if state.keyId != nil, !state.bundles.isEmpty {
            startSyncCheck()
        } else {
            syncCheckTask?.cancel()
            syncCheckTask = nil
        }
        guard availability.keyMatches, let remoteKeyId = state.keyId else { return }
        // The device is genuinely on the current key, so the user is no
        // longer in a locked/skipped state. Persist a baseline for the
        // periodic rotation check and clear any prior recovery skip.
        setDismissedRecoveryKeyId(nil)
        UserDefaults.standard.set(
            remoteKeyId,
            forKey: Constants.StorageKeys.Secret.passkeyEnclaveKeyId
        )
    }

    static func finishRecoveryRetry(
        appliedResult: PasskeyRecoveryResult,
        isCurrentAccount: Bool,
        dismiss: () -> Void,
        resume: (() -> Void)?
    ) -> Bool {
        guard case .success = appliedResult, isCurrentAccount else { return false }
        dismiss()
        resume?()
        return true
    }

    struct RecoveryAccountSnapshot {
        let userId: String
        let generation: Int
    }

    static func canApplyCurrentRecovery(
        recoveredKeyId: String,
        credentialId: String,
        currentState: KeyState,
        expectedAccount: RecoveryAccountSnapshot,
        currentUserId: String?,
        currentGeneration: Int
    ) -> Bool {
        recoveredKeyId == currentState.keyId
            && currentState.bundles.values.contains { $0.credentialId == credentialId }
            && expectedAccount.userId == currentUserId
            && expectedAccount.generation == currentGeneration
    }

    private func recoveryAccountSnapshot() -> RecoveryAccountSnapshot? {
        guard let userId = Clerk.shared.user?.id else { return nil }
        return RecoveryAccountSnapshot(userId: userId, generation: accountGeneration)
    }

    static func isExpectedRecoveryAccount(
        _ expectedAccount: RecoveryAccountSnapshot,
        currentUserId: String?,
        currentGeneration: Int
    ) -> Bool {
        expectedAccount.userId == currentUserId
            && expectedAccount.generation == currentGeneration
    }

    static func takeRecoveryCompletion(_ completion: inout (() -> Void)?) -> (() -> Void)? {
        let callback = completion
        completion = nil
        return callback
    }

    private var canMutateAccountKey: Bool {
        accountOperationsEnabled && !Task.isCancelled
    }

    private func applyRecoveredCek(cek: Data) async throws {
        guard canMutateAccountKey else { throw CancellationError() }
        let bytes = try await snapshotCurrentKeys()
        guard canMutateAccountKey else { throw CancellationError() }
        do {
            try await EncryptionService.shared.setKeyBytes(cek)
            guard canMutateAccountKey else {
                throw CancellationError()
            }
        } catch {
            try EncryptionService.shared.replaceKeyBundle(
                primary: bytes.primary,
                alternatives: bytes.alternatives
            )
            throw error
        }

        guard canMutateAccountKey else { throw CancellationError() }
        try await CloudKeyAuthorizationStore.shared.validateCurrentPrimaryKey(rollingBackTo: bytes)
        guard canMutateAccountKey else {
            try EncryptionService.shared.replaceKeyBundle(
                primary: bytes.primary,
                alternatives: bytes.alternatives
            )
            throw CancellationError()
        }
    }

    /// Puts a key the registry just registered in place. A start-fresh
    /// discards the keys it replaces, as the registry deleted their rows.
    private func applyFreshCek(cek: Data, discardingHistory: Bool) async throws {
        guard canMutateAccountKey else { throw CancellationError() }
        let bytes = try await snapshotCurrentKeys()
        guard canMutateAccountKey else { throw CancellationError() }
        do {
            try await EncryptionService.shared.setKeyBytes(cek, discardingHistory: discardingHistory)
            guard canMutateAccountKey else {
                throw CancellationError()
            }
        } catch {
            try EncryptionService.shared.replaceKeyBundle(
                primary: bytes.primary,
                alternatives: bytes.alternatives
            )
            throw error
        }
    }

    private func snapshotCurrentKeys() async throws -> CloudKeySnapshot {
        return try EncryptionService.shared.getAllKeys()
    }

    private func ensureCurrentPrimaryKeyAuthorized() async -> Bool {
        await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey().canWrite
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

    /// The registry's key_id is derived from the local CEK by HKDF —
    /// it's safe to cache locally and lets the periodic key check
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

    // MARK: - Periodic Key Check

    /// Periodically calls `/v1/keys/current` and detects when another
    /// device wiped + re-registered the user's key. When the keyId
    /// changes, the local CEK is invalidated and a fresh recovery
    /// flow is required.
    func startSyncCheck() {
        guard accountOperationsEnabled else { return }
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
        guard canMutateAccountKey else { return }
        do {
            let state = try await KeyRegistry.shared.current()
            guard canMutateAccountKey else { return }
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
            guard canMutateAccountKey else { return }
            switch result {
            case .success(let cek, let keyIdHex, _, _):
                do {
                    try await applyRecoveredCek(cek: cek)
                    guard canMutateAccountKey else { return }
                    persistEnclaveKeyId(keyIdHex)
                    onKeyRefreshedFromBackup?()
                } catch {
                    guard canMutateAccountKey else { return }
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
