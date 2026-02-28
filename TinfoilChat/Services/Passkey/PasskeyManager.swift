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
    case newUserSetupCancelled
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
        UserDefaults.standard.removeObject(forKey: Constants.Passkey.syncVersionUserDefaultsKey)
    }

    // MARK: - Recovery Flow

    /// Attempt to recover encryption keys via passkey, or auto-generate for new users.
    func attemptPasskeyKeyRecovery() async -> PasskeyRecoveryResult {
        do {
            let credentials = try await keyStorage.loadCredentials()

            if credentials.isEmpty {
                let created = await attemptNewUserPasskeySetup()
                if !created {
                    passkeySetupAvailable = true
                }
                return created ? .newUserSetupDone : .newUserSetupCancelled
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

            // Write recovered keys to keychain and enable cloud sync
            try await EncryptionService.shared.setAllKeys(
                primary: recovery.bundle.primary,
                alternatives: recovery.bundle.alternatives
            )

            // Record sync_version so the periodic check has a baseline
            if let entry = credentials.first(where: { $0.id == recovery.credentialId }) {
                setLocalSyncVersion(credentialId: recovery.credentialId, version: entry.sync_version)
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
    private func attemptNewUserPasskeySetup() async -> Bool {
        guard let user = await Clerk.shared.user else { return false }

        let newKey = EncryptionService.shared.generateKey()

        do {
            let (credentialId, kek) = try await createPasskeyAndDeriveKEK(for: user)
            let bundle = KeyBundle(primary: newKey, alternatives: [])

            let syncVersion = try await keyStorage.storeEncryptedKeys(
                credentialId: credentialId,
                kek: kek,
                keys: bundle
            )
            setLocalSyncVersion(credentialId: credentialId, version: syncVersion)

            // Passkey created and stored — persist the key
            try await EncryptionService.shared.setKey(newKey)
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

            try await EncryptionService.shared.setAllKeys(
                primary: recovery.bundle.primary,
                alternatives: recovery.bundle.alternatives
            )

            if let entry = entries.first(where: { $0.id == recovery.credentialId }) {
                setLocalSyncVersion(credentialId: recovery.credentialId, version: entry.sync_version)
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
        let success = await attemptNewUserPasskeySetup()
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
    func retryPasskeySetup() async {
        if EncryptionService.shared.hasEncryptionKey() {
            await createPasskeyBackup()
        } else {
            await attemptNewUserPasskeySetup()
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
        if let metadata = await Clerk.shared.user?.unsafeMetadata,
           case .object(let dict) = metadata,
           case .bool(let seen) = dict[Constants.Passkey.hasSeenIntroKey] {
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
        guard let user = await Clerk.shared.user else { return }

        do {
            let keys = EncryptionService.shared.getAllKeys()
            guard let primary = keys.primary else { return }

            let (credentialId, kek) = try await createPasskeyAndDeriveKEK(for: user)
            let bundle = KeyBundle(primary: primary, alternatives: keys.alternatives)

            let syncVersion = try await keyStorage.storeEncryptedKeys(
                credentialId: credentialId,
                kek: kek,
                keys: bundle
            )
            setLocalSyncVersion(credentialId: credentialId, version: syncVersion)

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

            let bundle = KeyBundle(primary: primary, alternatives: keys.alternatives)

            let syncVersion = try await keyStorage.storeEncryptedKeys(
                credentialId: result.credentialId,
                kek: kek,
                keys: bundle
            )
            setLocalSyncVersion(credentialId: result.credentialId, version: syncVersion)
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
        guard let user = await Clerk.shared.user else { return }

        var existingMetadata: [String: JSON] = [:]
        if case .object(let dict) = user.unsafeMetadata {
            existingMetadata = dict
        }
        existingMetadata[Constants.Passkey.hasSeenIntroKey] = .bool(true)

        let params = User.UpdateParams(unsafeMetadata: .object(existingMetadata))
        try? await user.update(params)
    }

    // MARK: - Sync Version Tracking

    private func getLocalSyncVersion(credentialId: String) -> Int? {
        let dict = UserDefaults.standard.dictionary(forKey: Constants.Passkey.syncVersionUserDefaultsKey)
        return dict?[credentialId] as? Int
    }

    private func setLocalSyncVersion(credentialId: String, version: Int) {
        var dict = UserDefaults.standard.dictionary(forKey: Constants.Passkey.syncVersionUserDefaultsKey) ?? [:]
        dict[credentialId] = version
        UserDefaults.standard.set(dict, forKey: Constants.Passkey.syncVersionUserDefaultsKey)
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

            let localKey = EncryptionService.shared.getAllKeys().primary
            if bundle.primary == localKey {
                // Key matches — just record the version
                setLocalSyncVersion(credentialId: cached.credentialId, version: entry.sync_version)
                return
            }

            // Key differs — apply the recovered key bundle
            try await EncryptionService.shared.setAllKeys(
                primary: bundle.primary,
                alternatives: bundle.alternatives
            )
            setLocalSyncVersion(credentialId: cached.credentialId, version: entry.sync_version)

            #if DEBUG
            print("[PasskeyManager] Refreshed encryption key from passkey backup (sync_version: \(entry.sync_version))")
            #endif

            onKeyRefreshedFromBackup?()
        } catch {
            // Non-fatal — will retry on next interval
        }
    }
}
