//
//  PasskeyManager.swift
//  TinfoilChat
//
//  Manages passkey lifecycle: creation, recovery, backup updates, and UI state.
//  Extracted from ChatViewModel to keep the ViewModel focused on view coordination.
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
    @Published var showPasskeyIntro: Bool = false
    @Published var showPasskeyRecoveryChoice: Bool = false

    // MARK: - Callbacks

    /// Called after successful recovery/fresh-start to resume the sign-in flow.
    var onRecoveryComplete: (() -> Void)?

    /// Called when the periodic sync check detects a key change from another device
    /// and applies it locally. The consumer should retry decryption of failed chats.
    var onKeyRefreshedFromBackup: (() -> Void)?

    // MARK: - Private

    private var introTask: Task<Void, Never>?
    private var syncCheckTask: Task<Void, Never>?
    private let passkeyService = PasskeyService.shared
    private let keyStorage = PasskeyKeyStorage.shared

    private init() {}

    // MARK: - Sign-Out Reset

    func reset() {
        passkeyActive = false
        passkeySetupAvailable = false
        showPasskeyIntro = false
        showPasskeyRecoveryChoice = false
        onRecoveryComplete = nil
        onKeyRefreshedFromBackup = nil
        introTask?.cancel()
        introTask = nil
        syncCheckTask?.cancel()
        syncCheckTask = nil
        passkeyService.clearCachedPrfResult()
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Secret.passkeySyncVersion)
        UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Secret.passkeyBundleVersion)
    }

    // MARK: - Recovery Flow

    /// Attempt to recover encryption keys via passkey, or auto-generate for new users.
    func attemptPasskeyKeyRecovery() async -> PasskeyRecoveryResult {
        do {
            let credentials = try await keyStorage.loadCredentials()

            if credentials.isEmpty {
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

            // Try recovery with all credential IDs — shows system passkey UI
            // (iCloud Keychain, nearby devices, etc.)
            let allIds = credentials.map(\.id)
            guard let recovery = try await recoverKeyBundle(credentialIds: allIds) else {
                #if DEBUG
                print("[PasskeyManager] Failed to decrypt key bundle")
                #endif
                showPasskeyRecoveryChoice = true
                return .recoveryFailed
            }

            _ = try await applyRecoveredKeyBundle(recovery.bundle)

            // Record sync_version so the periodic check has a baseline
            if let entry = credentials.first(where: { $0.id == recovery.credentialId }) {
                setLocalSyncVersion(credentialId: recovery.credentialId, version: entry.sync_version)
                setLocalBundleVersion(entry.bundle_version ?? 0)
            }

            activatePasskey()
            return .success

        } catch {
            #if DEBUG
            print("[PasskeyManager] Recovery failed with error: \(error)")
            #endif
            showPasskeyRecoveryChoice = true
            return .recoveryFailed
        }
    }

    /// Auto-generate a key and create a passkey for a brand new user.
    /// Returns true if successful, false if passkey creation was cancelled (key is discarded).
    @discardableResult
    private func attemptNewUserPasskeySetup(
        authorizationMode: CloudKeyAuthorizationMode = .validated
    ) async -> Bool {
        guard let user = Clerk.shared.user else { return false }

        let newKey = EncryptionService.shared.generateKey()

        do {
            let (credentialId, kek) = try await createPasskeyAndDeriveKEK(for: user)
            let bundle = KeyBundle(
                primary: newKey,
                alternatives: [],
                authorizationMode: authorizationMode
            )

            let saveResult = try await keyStorage.storeEncryptedKeys(
                credentialId: credentialId,
                kek: kek,
                keys: bundle,
                options: PasskeyCredentialWriteOptions(
                    knownBundleVersion: getLocalBundleVersion(),
                    incrementBundleVersion: authorizationMode == .explicitStartFresh,
                    enforceRemoteBundleVersion: authorizationMode != .explicitStartFresh
                )
            )
            setLocalSyncVersion(credentialId: credentialId, version: saveResult.syncVersion)
            setLocalBundleVersion(saveResult.bundleVersion)

            // Passkey created and stored — persist the key
            try await EncryptionService.shared.setKey(newKey)
            guard CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: authorizationMode) else {
                EncryptionService.shared.clearKey()
                throw CloudKeyAuthorizationError.authorizationUnavailable
            }
            activatePasskey()
            return true

        } catch {
            // Passkey creation failed or user cancelled Face ID — discard the generated key, fall back
            #if DEBUG
            print("[PasskeyManager] New user passkey setup failed: \(error)")
            #endif
            return false
        }
    }

    // MARK: - Recovery Choice Actions

    /// Retry passkey recovery with full auth (system UI including "Use a Device Nearby").
    /// Called from PasskeyRecoveryChoiceView's "Try Again" button.
    func retryPasskeyRecovery() async -> Bool {
        do {
            let allIds = await keyStorage.allCredentialIds()
            guard !allIds.isEmpty else { return false }

            let entries = try await keyStorage.loadCredentials()
            guard let recovery = try await recoverKeyBundle(credentialIds: allIds) else {
                return false
            }

            _ = try await applyRecoveredKeyBundle(recovery.bundle)

            if let entry = entries.first(where: { $0.id == recovery.credentialId }) {
                setLocalSyncVersion(credentialId: recovery.credentialId, version: entry.sync_version)
                setLocalBundleVersion(entry.bundle_version ?? 0)
            }

            activatePasskey()
            showPasskeyRecoveryChoice = false

            // Continue sign-in flow now that key is available
            onRecoveryComplete?()
            return true
        } catch {
            #if DEBUG
            print("[PasskeyManager] Retry passkey recovery failed: \(error)")
            #endif
            return false
        }
    }

    /// Generate a new key and create a new passkey (explicit split).
    /// Called from PasskeyRecoveryChoiceView's "Start Fresh" button.
    func startFreshWithNewKey() async -> Bool {
        let success = await attemptNewUserPasskeySetup(authorizationMode: .explicitStartFresh)
        if success {
            showPasskeyRecoveryChoice = false
            onRecoveryComplete?()
        }
        return success
    }

    // MARK: - Setup & Backup

    /// Retry passkey setup. When an encryption key already exists, creates a passkey
    /// backup for it. When no key exists, runs the new-user flow that generates a key
    /// and creates a passkey in one step.
    /// Called from Settings when cloud sync toggle is turned ON without a passkey.
    func retryPasskeySetup() async -> PasskeyRecoveryResult {
        if EncryptionService.shared.hasEncryptionKey() {
            guard await ensureCurrentPrimaryKeyAuthorized() else {
                passkeySetupAvailable = true
                return .manualRecoveryRequired
            }
            await createPasskeyBackup()
            return .success
        } else {
            return await attemptPasskeyKeyRecovery()
        }
    }

    /// Check passkey state for users who already have keys loaded.
    /// Shows the intro modal if they haven't seen it and have no passkey backup.
    func checkPasskeyStateForExistingKey() async {
        let hasCredentials = await keyStorage.hasCredentials()
        if hasCredentials {
            passkeyActive = true
            startSyncCheck()
            return
        }

        // No passkey credentials — check if user has seen the intro
        let hasSeenIntro: Bool
        if let metadata = Clerk.shared.user?.unsafeMetadata,
           case .object(let dict) = metadata,
           case .bool(let seen) = dict[Constants.StorageKeys.Settings.hasSeenPasskeyIntro] {
            hasSeenIntro = seen
        } else {
            hasSeenIntro = false
        }

        passkeySetupAvailable = true
        if !hasSeenIntro {
            // Show intro after a short delay to not interrupt sign-in
            introTask?.cancel()
            introTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Constants.Passkey.introDelaySeconds))
                guard !Task.isCancelled else { return }
                if self.passkeySetupAvailable && !self.passkeyActive {
                    self.showPasskeyIntro = true
                }
            }
        }
    }

    /// Create a passkey backup for the user's existing keys.
    /// Called from PasskeyIntroView's onAccept and Settings backup button.
    func createPasskeyBackup() async {
        guard let user = Clerk.shared.user else { return }
        guard await ensureCurrentPrimaryKeyAuthorized() else { return }

        do {
            let keys = EncryptionService.shared.getAllKeys()
            guard let primary = keys.primary else { return }

            let (credentialId, kek) = try await createPasskeyAndDeriveKEK(for: user)
            let bundle = KeyBundle(
                primary: primary,
                alternatives: keys.alternatives,
                authorizationMode: CloudKeyAuthorizationStore.shared.currentMode() ?? .validated
            )

            let saveResult = try await keyStorage.storeEncryptedKeys(
                credentialId: credentialId,
                kek: kek,
                keys: bundle,
                options: PasskeyCredentialWriteOptions(
                    knownBundleVersion: getLocalBundleVersion(),
                    incrementBundleVersion: false,
                    enforceRemoteBundleVersion: true
                )
            )
            setLocalSyncVersion(credentialId: credentialId, version: saveResult.syncVersion)
            setLocalBundleVersion(saveResult.bundleVersion)

            // Mark intro as seen in Clerk unsafeMetadata
            await markPasskeyIntroSeen()

            passkeyActive = true
            passkeySetupAvailable = false
            showPasskeyIntro = false
            startSyncCheck()
        } catch {
            // Passkey creation failed or cancelled — leave state unchanged
            showPasskeyIntro = false
        }
    }

    /// Re-encrypt the locally-available passkey credential with the current key bundle.
    /// Called after key changes (e.g. importing a key from another device) to keep
    /// the passkey backup in sync. Uses silent auth to avoid confusing biometric
    /// prompts when credentials aren't locally available.
    ///
    /// Only the credential that responds to silent auth is re-encrypted. Credentials
    /// registered on other devices retain their old key bundle until that device
    /// performs its own updatePasskeyBackup. If that device is lost, the stale
    /// credential can still decrypt the keys it was last updated with — the user
    /// would need to create a new passkey on a replacement device.
    func updatePasskeyBackup() async {
        guard CloudKeyAuthorizationStore.shared.hasAuthorizedCurrentPrimaryKey() else { return }

        do {
            let keys = EncryptionService.shared.getAllKeys()
            guard let primary = keys.primary else { return }

            let entries = try await keyStorage.loadCredentials()
            guard !entries.isEmpty else { return }

            // Use the cached PRF result to avoid re-prompting biometrics.
            // Falls back to silent auth if no cache is available.
            let allIds = entries.map(\.id)
            let result: PrfPasskeyResult
            if let cached = passkeyService.getCachedPrfResult(),
               entries.contains(where: { $0.id == cached.credentialId }) {
                result = cached
            } else {
                result = try await passkeyService.authenticatePasskey(
                    credentialIds: allIds,
                    silent: true
                )
            }
            let kek = PasskeyService.deriveKeyEncryptionKey(from: result.prfOutput)

            let bundle = KeyBundle(
                primary: primary,
                alternatives: keys.alternatives,
                authorizationMode: CloudKeyAuthorizationStore.shared.currentMode() ?? .validated
            )

            var localSyncVersion = getLocalSyncVersion(credentialId: result.credentialId)
            var localBundleVersion = getLocalBundleVersion()

            if (localSyncVersion == nil || localBundleVersion == nil),
               let currentEntry = entries.first(where: { $0.id == result.credentialId }) {
                let currentRemoteBundle = try keyStorage.decryptKeyBundle(
                    kek: kek,
                    iv: currentEntry.iv,
                    data: currentEntry.encrypted_keys
                )

                if await doesCurrentStateMatchBundle(currentRemoteBundle) {
                    if localSyncVersion == nil {
                        localSyncVersion = currentEntry.sync_version
                    }
                    if localBundleVersion == nil {
                        localBundleVersion = currentEntry.bundle_version ?? 0
                    }
                }
            }

            let saveResult = try await keyStorage.storeEncryptedKeys(
                credentialId: result.credentialId,
                kek: kek,
                keys: bundle,
                options: PasskeyCredentialWriteOptions(
                    expectedSyncVersion: localSyncVersion,
                    knownBundleVersion: localBundleVersion,
                    incrementBundleVersion: true,
                    enforceRemoteBundleVersion: true
                )
            )
            setLocalSyncVersion(credentialId: result.credentialId, version: saveResult.syncVersion)
            setLocalBundleVersion(saveResult.bundleVersion)
        } catch {
            // Non-fatal — passkey backup is stale but user can re-backup from Settings
        }
    }

    // MARK: - Intro Dismissal

    /// Called when the PasskeyIntroView sheet is dismissed (either after accept or swipe-down).
    /// Marks the intro as seen so it won't re-appear.
    func handlePasskeyIntroDismissed() async {
        if !passkeyActive {
            await markPasskeyIntroSeen()
        }
    }

    // MARK: - Private Helpers

    private func activatePasskey() {
        SettingsManager.shared.isCloudSyncEnabled = true
        passkeyActive = true
        startSyncCheck()
    }

    private func applyRecoveredKeyBundle(_ bundle: KeyBundle) async throws -> CloudKeyAuthorizationMode {
        let authorizationMode = bundle.authorizationMode ?? .validated

        return try await CloudKeyAuthorizationStore.shared.applyKeyBundleWithValidation(
            primary: bundle.primary,
            alternatives: bundle.alternatives,
            successMode: authorizationMode,
            failureMode: authorizationMode == .explicitStartFresh ? .explicitStartFresh : nil
        )
    }

    private func ensureCurrentPrimaryKeyAuthorized() async -> Bool {
        if CloudKeyAuthorizationStore.shared.hasAuthorizedCurrentPrimaryKey() {
            return true
        }

        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
        guard validation.canWrite else { return false }

        return CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: .validated)
    }

    /// Authenticate with a passkey, derive the KEK, and decrypt the stored key bundle.
    /// Returns the bundle and the credential ID that was used.
    private func recoverKeyBundle(credentialIds: [String], silent: Bool = false) async throws -> (bundle: KeyBundle, credentialId: String)? {
        let result = try await passkeyService.authenticatePasskey(
            credentialIds: credentialIds,
            silent: silent
        )
        let kek = PasskeyService.deriveKeyEncryptionKey(from: result.prfOutput)
        guard let bundle = try await keyStorage.retrieveEncryptedKeys(
            credentialId: result.credentialId,
            kek: kek
        ) else {
            return nil
        }
        return (bundle: bundle, credentialId: result.credentialId)
    }

    /// Create a passkey for the given user and derive its KEK.
    private func createPasskeyAndDeriveKEK(for user: User) async throws -> (credentialId: String, kek: SymmetricKey) {
        let email = user.emailAddresses.first?.emailAddress ?? ""
        let displayName = [user.firstName, user.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let result = try await passkeyService.createPasskey(
            userId: user.id,
            userEmail: email,
            displayName: displayName.isEmpty ? email : displayName
        )

        let kek = PasskeyService.deriveKeyEncryptionKey(from: result.prfOutput)
        return (credentialId: result.credentialId, kek: kek)
    }

    /// Mark the passkey intro as seen in Clerk unsafeMetadata.
    private func markPasskeyIntroSeen() async {
        guard let user = Clerk.shared.user else { return }

        var existingMetadata: [String: JSON] = [:]
        if case .object(let dict) = user.unsafeMetadata {
            existingMetadata = dict
        }
        existingMetadata[Constants.StorageKeys.Settings.hasSeenPasskeyIntro] = .bool(true)

        let params = User.UpdateParams(unsafeMetadata: .object(existingMetadata))
        _ = try? await user.update(params)
    }

    // MARK: - Sync Version Tracking

    private func getLocalSyncVersion(credentialId: String) -> Int? {
        let dict = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.Secret.passkeySyncVersion)
        return dict?[credentialId] as? Int
    }

    private func setLocalSyncVersion(credentialId: String, version: Int) {
        var dict = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.Secret.passkeySyncVersion) ?? [:]
        dict[credentialId] = version
        UserDefaults.standard.set(dict, forKey: Constants.StorageKeys.Secret.passkeySyncVersion)
    }

    private func getLocalBundleVersion() -> Int? {
        let value = UserDefaults.standard.object(forKey: Constants.StorageKeys.Secret.passkeyBundleVersion)
        return value as? Int
    }

    private func setLocalBundleVersion(_ version: Int) {
        UserDefaults.standard.set(version, forKey: Constants.StorageKeys.Secret.passkeyBundleVersion)
    }

    private func doesCurrentStateMatchBundle(_ bundle: KeyBundle) async -> Bool {
        let currentKeys = EncryptionService.shared.getAllKeys()
        guard currentKeys.primary == bundle.primary else {
            return false
        }

        let normalizeAlternatives: (String, [String]) -> [String] = { primary, alternatives in
            alternatives
                .filter { $0 != primary }
                .sorted()
        }

        let currentAlternatives = normalizeAlternatives(bundle.primary, currentKeys.alternatives)
        let bundleAlternatives = normalizeAlternatives(bundle.primary, bundle.alternatives)
        guard currentAlternatives == bundleAlternatives else {
            return false
        }

        return CloudKeyAuthorizationStore.shared.currentMode() ==
            (bundle.authorizationMode ?? .validated)
    }

    // MARK: - Periodic Sync Check

    /// Start a repeating timer that checks whether another device has updated
    /// the passkey backup (sync_version changed). If so, decrypts the updated
    /// backup using the cached PRF and applies the new keys locally.
    func startSyncCheck() {
        syncCheckTask?.cancel()
        syncCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.Passkey.syncCheckIntervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.refreshKeyFromPasskeyBackup()
            }
        }
    }

    /// Check if the passkey backup has been updated by another device.
    /// Uses the cached PRF to avoid biometric prompts. If no cached PRF
    /// is available, the check is skipped silently.
    private func refreshKeyFromPasskeyBackup() async {
        var pendingRemoteVersion: (credentialId: String, syncVersion: Int, bundleVersion: Int)?

        do {
            guard let cached = passkeyService.getCachedPrfResult() else { return }

            let entries = try await keyStorage.loadCredentials()
            guard let entry = entries.first(where: { $0.id == cached.credentialId }) else { return }

            let localVersion = getLocalSyncVersion(credentialId: cached.credentialId)
            if let localVersion, entry.sync_version <= localVersion { return }

            // sync_version increased — another device updated the backup
            let kek = PasskeyService.deriveKeyEncryptionKey(from: cached.prfOutput)
            let bundle = try keyStorage.decryptKeyBundle(
                kek: kek,
                iv: entry.iv,
                data: entry.encrypted_keys
            )

            if await doesCurrentStateMatchBundle(bundle) {
                setLocalSyncVersion(credentialId: cached.credentialId, version: entry.sync_version)
                setLocalBundleVersion(entry.bundle_version ?? 0)
                return
            }

            pendingRemoteVersion = (
                credentialId: cached.credentialId,
                syncVersion: entry.sync_version,
                bundleVersion: entry.bundle_version ?? 0
            )
            let appliedMode = try await applyRecoveredKeyBundle(bundle)

            setLocalSyncVersion(credentialId: cached.credentialId, version: entry.sync_version)
            setLocalBundleVersion(entry.bundle_version ?? 0)

            #if DEBUG
            print("[PasskeyManager] Refreshed encryption key from passkey backup (sync_version: \(entry.sync_version), mode: \(appliedMode.rawValue))")
            #endif

            onKeyRefreshedFromBackup?()
        } catch {
            if error is CloudKeyAuthorizationError,
               let pendingRemoteVersion {
                setLocalSyncVersion(
                    credentialId: pendingRemoteVersion.credentialId,
                    version: pendingRemoteVersion.syncVersion
                )
                setLocalBundleVersion(pendingRemoteVersion.bundleVersion)
            }
            // Non-fatal — will retry on next interval
        }
    }
}
