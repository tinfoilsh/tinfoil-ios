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

    // MARK: - Private

    private var introTask: Task<Void, Never>?
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
        introTask?.cancel()
        introTask = nil
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
            guard let bundle = try await recoverKeyBundle(credentialIds: allIds) else {
                #if DEBUG
                print("[PasskeyManager] Failed to decrypt key bundle")
                #endif
                showPasskeyRecoveryChoice = true
                return .recoveryFailed
            }

            // Write recovered keys to keychain and enable cloud sync
            try await EncryptionService.shared.setAllKeys(
                primary: bundle.primary,
                alternatives: bundle.alternatives
            )
            SettingsManager.shared.isCloudSyncEnabled = true
            passkeyActive = true
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

            try await keyStorage.storeEncryptedKeys(
                credentialId: credentialId,
                kek: kek,
                keys: bundle
            )

            // Passkey created and stored — persist the key
            try await EncryptionService.shared.setKey(newKey)
            SettingsManager.shared.isCloudSyncEnabled = true
            passkeyActive = true
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

            guard let bundle = try await recoverKeyBundle(credentialIds: allIds) else {
                return false
            }

            try await EncryptionService.shared.setAllKeys(
                primary: bundle.primary,
                alternatives: bundle.alternatives
            )
            SettingsManager.shared.isCloudSyncEnabled = true
            passkeyActive = true
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

            try await keyStorage.storeEncryptedKeys(
                credentialId: credentialId,
                kek: kek,
                keys: bundle
            )

            // Mark intro as seen in Clerk unsafeMetadata
            await markPasskeyIntroSeen()

            passkeyActive = true
            passkeySetupAvailable = false
            showPasskeyIntro = false
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

            let allIds = entries.map(\.id)
            let result = try await passkeyService.authenticatePasskey(
                credentialIds: allIds,
                silent: true
            )
            let kek = PasskeyService.deriveKeyEncryptionKey(from: result.prfOutput)

            let bundle = KeyBundle(primary: primary, alternatives: keys.alternatives)

            try await keyStorage.storeEncryptedKeys(
                credentialId: result.credentialId,
                kek: kek,
                keys: bundle
            )
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

    /// Authenticate with a passkey, derive the KEK, and decrypt the stored key bundle.
    private func recoverKeyBundle(credentialIds: [String], silent: Bool = false) async throws -> KeyBundle? {
        let result = try await passkeyService.authenticatePasskey(
            credentialIds: credentialIds,
            silent: silent
        )
        let kek = PasskeyService.deriveKeyEncryptionKey(from: result.prfOutput)
        return try await keyStorage.retrieveEncryptedKeys(
            credentialId: result.credentialId,
            kek: kek
        )
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
}
