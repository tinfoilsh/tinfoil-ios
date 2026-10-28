import Foundation
import OSLog

extension ChatViewModel {
    // MARK: - Signing in and out

    /// Signs the account in once the app shows and the identity provider
    /// has confirmed who is signed in. A sign-in of the same account that
    /// is still running loads it.
    func handleSignIn() {
        guard let userId = currentUserId else { return }
        guard isAppPresentationReady, authManager?.isLoading == false else {
            needsSignInWhenPresentationReady = true
            return
        }
        // A key a passkey recovered, or one another device rotated to and
        // this one applied, loads the account again.
        passkeyManager.onRecoveryComplete = { [weak self] in self?.handleSignIn() }
        passkeyManager.onKeyRefreshedFromBackup = { [weak self] in Task { @MainActor in self?.handleSignIn() } }
        if let activeSignInToken, signInTask != nil, accountOperationFence.isCurrent(activeSignInToken, currentUserId: userId) { return }
        signInTask?.cancel()
        let token = accountOperationFence.begin(userId: userId)
        activeSignInToken = token
        signInTask = Task { [weak self] in
            await self?.performSignIn(token: token, userId: userId)
        }
    }

    private func isCurrentAccountOperation(_ token: AccountOperationFence.Token, userId: String) -> Bool {
        token.userId == userId && accountOperationFence.isCurrent(token, currentUserId: currentUserId)
    }

    private func isCurrentSignIn(_ token: AccountOperationFence.Token, userId: String) -> Bool {
        !Task.isCancelled && isCurrentAccountOperation(token, userId: userId)
    }

    /// The token of the sign-in in progress, or a new one for an operation
    /// after it.
    private func currentAccountOperationToken(userId: String) -> AccountOperationFence.Token {
        if let activeSignInToken, accountOperationFence.isCurrent(activeSignInToken, currentUserId: userId) {
            return activeSignInToken
        }
        let token = accountOperationFence.begin(userId: userId)
        activeSignInToken = token
        return token
    }

    private func finishSignIn(_ token: AccountOperationFence.Token, userId: String) {
        guard isCurrentSignIn(token, userId: userId) else { return }
        if activeSignInToken == token { activeSignInToken = nil }
        signInTask = nil
        readyForAccountActionsUserId = userId
    }

    /// Opens the account's session, unlocks its content key through a
    /// passkey or the user, and loads its chats.
    private func performSignIn(token: AccountOperationFence.Token, userId: String) async {
        guard isCurrentSignIn(token, userId: userId) else { return }
        EncryptionService.shared.bind(userId: userId)
        isAccountTeardownInProgress = false
        passkeyManager.resumeAccountOperations()
        await openSession()
        guard isCurrentSignIn(token, userId: userId) else { return }
        // Local chats with messages turn the Local tab on, unless the user
        // chose otherwise.
        if session?.list.deviceListed.contains(where: { $0.messageCount > 0 }) == true,
           UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.localOnlyModeEnabled) == nil {
            SettingsManager.shared.isLocalOnlyModeEnabled = true
        }
        // If no cloud key exists, try passkey recovery before falling back
        if !EncryptionService.shared.hasEncryptionKey() {
            passkeySetupFailure = nil
            let result = await passkeyManager.attemptPasskeyKeyRecovery()
            guard isCurrentSignIn(token, userId: userId) else { return }
            switch result {
            case .success, .newUserSetupDone:
                break
            case .manualSetupRequired:
                cloudSyncOnboardingMode = .setup
                showCloudSyncOnboarding = true
                finishSignIn(token, userId: userId)
                return
            case .manualRecoveryRequired:
                cloudSyncOnboardingMode = .recovery
                showCloudSyncOnboarding = true
                finishSignIn(token, userId: userId)
                return
            case .temporarilyUnavailable:
                needsSignInWhenPresentationReady = true
                finishSignIn(token, userId: userId)
                return
            case .setupFailed(let failure):
                passkeySetupFailure = failure
                finishSignIn(token, userId: userId)
                return
            case .recoveryFailed:
                finishSignIn(token, userId: userId)
                return
            }
        }
        do {
            _ = try await EncryptionService.shared.initialize()
        } catch {
            Self.logger.error("Failed to load the encryption key: \(error, privacy: .public)")
        }
        guard isCurrentSignIn(token, userId: userId) else { return }
        // A local key that mismatches the enclave's registered key can never
        // open the account's chats. Converge silently via passkey when
        // possible; otherwise prompt the user to recover.
        if SettingsManager.shared.isCloudSyncEnabled {
            let mismatch = await passkeyManager.resolveKeyMismatchAtLaunch()
            guard isCurrentSignIn(token, userId: userId) else { return }
            if mismatch == .manualRecoveryRequired {
                cloudSyncOnboardingMode = .recovery
                showCloudSyncOnboarding = true
            }
        }
        await passkeyManager.checkPasskeyStateForExistingKey()
        guard isCurrentSignIn(token, userId: userId) else { return }
        registerHeldKey(token: token, userId: userId)
        await keyChanged()
        guard isCurrentSignIn(token, userId: userId) else { return }
        if SettingsManager.shared.isCloudSyncEnabled, let saved = UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab).flatMap(ChatStorageTab.init(rawValue:)) {
            activeStorageTab = saved
        } else if !SettingsManager.shared.isCloudSyncEnabled {
            activeStorageTab = .local
        }
        if currentChat == nil || currentChat?.id.isEmpty == true { createNewChat(focusInput: false) }
        finishSignIn(token, userId: userId)
    }

    /// The content key was set, recovered or rotated: the account's chats and
    /// settings load again with it. The key the account already read its
    /// settings with changes nothing, so the list and the open chat stay.
    func keyChanged() async {
        guard let session, !session.account.readsHeldKey else { return }
        session.account.invalidateKey()
        session.list.clearCloud()
        if !session.open.onDevice { session.newChat(local: false) }
        session.controller.clearReceipt()
        await session.account.refreshProfile()
        if session.account.keyReady {
            session.list.reload()
            await loadProjects()
        }
    }

    func handleSignOut() async {
        speechPlayer.stop()
        cancelMessageEdit()
        cancelAudioRecording()
        clearPendingAttachments()
        isAccountTeardownInProgress = true
        clearProjectState()
        signInTask?.cancel()
        signInTask = nil
        activeSignInToken = nil
        heldKeyRegistrationTask?.cancel()
        heldKeyRegistrationTask = nil
        await accountOperationTracker.closeAndWait()
        session?.account.dispose()
        session = nil
        EncryptionService.shared.bind(userId: nil)
        passkeySetupFailure = nil
        await passkeyManager.reset()
        activeStorageTab = .cloud
        isViewingProjectChat = false
        readyForAccountActionsUserId = nil
    }

    /// The account's teardown ended: a signed-out session opens.
    func completeAccountTeardown() {
        isAccountTeardownInProgress = false
        accountOperationTracker.reopen()
        Task { await openSession() }
    }

    /// Wipes the chats this device kept for the account signing out.
    func wipeLocalChatsForSignOut() async {
        guard let userId = currentUserId else { return }
        session?.account.dispose()
        session = nil
        Self.wipeDeviceChats(userId: userId)
    }

    /// Removes what this device kept for the account: its chats, cloud
    /// settings, run receipt and prompt cache secret, and what older clients
    /// kept for it.
    static func wipeDeviceChats(userId: String) {
        if let directory = try? DeviceThreadStore.directory(userId: userId) {
            try? FileManager.default.removeItem(at: directory)
        }
        DeviceProfileStorage().clearCloudProfileCache(userId: userId)
        LegacyDeviceChats.wipe(userId: userId)
        PromptCacheSecret.forget(userId: userId)
        RunReceiptStore(userId: userId).clear()
        LegacyStoragePurge.purge(userId: userId)
    }

    /// The account's subscription changed: its chat access is minted again,
    /// and the session read again for what it now offers.
    func subscriptionChanged() {
        guard let session else { return }
        Task {
            do { try await session.account.refresh(credentials: true) } catch { session.account.report(error) }
        }
    }

    /// Stops narration for the account that signed out or changed.
    func invalidateAccountPlayback() {
        guard speechPlayer.snapshot.owner != nil else { return }
        speechPlayer.stop()
    }

    func updateModelBasedOnAuthStatus(isAuthenticated: Bool, hasActiveSubscription: Bool) {
        guard let session else { return }
        Task {
            do { try await session.account.refresh(credentials: true) } catch { session.account.report(error) }
            if isAuthenticated { await loadProjects() }
        }
    }

    // MARK: - Legacy rows

    /// A held key the registry does not know becomes the account's, and
    /// rows older keys sealed are resealed under it by the harness.
    func registerHeldKey(token: AccountOperationFence.Token, userId: String) {
        let previousTask = heldKeyRegistrationTask
        previousTask?.cancel()
        heldKeyRegistrationTask = Task { [weak self] in
            await previousTask?.value
            guard let self, isCurrentSignIn(token, userId: userId) else { return }
            do {
                try await CloudKeyAuthorizationStore.shared.registerHeldKeyIfNeeded()
            } catch {
                guard !(error is CancellationError) else { return }
                Self.logger.error("Failed to register the held key: \(error, privacy: .public)")
            }
            guard isCurrentSignIn(token, userId: userId) else { return }
            await passkeyManager.refreshBundleState()
        }
    }

    // MARK: - Keys and passkeys

    func getCurrentEncryptionKey() -> String? {
        EncryptionService.shared.getKey()
    }

    func reloadEncryptionKey() {
        Task { await keyChanged() }
    }

    func initializeExistingEncryptionKeyIfAvailable() async {
        guard currentUserId != nil, EncryptionService.shared.hasEncryptionKey() else { return }
        let operationTask = Task {
            guard !Task.isCancelled else { return }
            _ = try? await EncryptionService.shared.initialize()
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            return
        }
        defer { accountOperationTracker.end(operationToken) }
        await operationTask.value
    }

    /// Sets the content key, recovering the account's data with it or
    /// starting the account afresh.
    func setEncryptionKey(_ key: String, mode: CloudKeyActivationMode = .recoverExisting) async throws {
        guard let operationUserId = currentUserId else { throw CancellationError() }
        let operationTask = Task {
            try await self.performSetEncryptionKey(key, mode: mode, operationUserId: operationUserId)
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            throw CancellationError()
        }
        defer { accountOperationTracker.end(operationToken) }
        try await operationTask.value
        try ensureCurrentAccount(operationUserId)
        // A v1 user activating their key on a fresh device has legacy cloud
        // data but no registered key. Re-kick migration now that a key is
        // active so adoption happens in-session.
        registerHeldKey(token: currentAccountOperationToken(userId: operationUserId), userId: operationUserId)
    }

    private func performSetEncryptionKey(_ key: String, mode: CloudKeyActivationMode, operationUserId: String) async throws {
        try Task.checkCancellation()
        do {
            switch mode {
            case .recoverExisting:
                try await CloudKeyAuthorizationStore.shared.applyPrimaryKeyWithValidation(key)
                try ensureCurrentAccount(operationUserId)
            case .explicitStartFresh:
                // Stage the key in memory so the enclave handshake runs
                // against it without writing it to the Keychain first. Only
                // after the enclave registers the start-fresh key do we
                // persist it, so a new key is never stranded locally while
                // the enclave keeps the old one.
                var remoteRegistrationCommitted = false
                do {
                    try await EncryptionService.shared.setKey(key, persist: false)
                    try ensureCurrentAccount(operationUserId)
                    try await CloudKeyAuthorizationStore.shared.registerStartFreshKeyIfNeeded()
                    remoteRegistrationCommitted = true
                    try EncryptionService.shared.persistCurrentKeyState(discardingHistory: true)
                } catch {
                    if !remoteRegistrationCommitted { EncryptionService.shared.discardStagedKeyState() }
                    throw error
                }
            }
            try ensureCurrentAccount(operationUserId)
            await keyChanged()
            try ensureCurrentAccount(operationUserId)
            if passkeyManager.passkeyActive {
                await passkeyManager.updatePasskeyBackup()
                try ensureCurrentAccount(operationUserId)
            }
        } catch {
            guard currentUserId == operationUserId else { throw CancellationError() }
            throw error
        }
    }

    func retryPasskeyRecovery() async -> Bool {
        guard let operationUserId = currentUserId else {
            PasskeyDiagnostics.failure("retryRecovery: no current user id (auth still settling?)")
            return false
        }
        let operationTask = Task { [passkeyManager] in
            guard !Task.isCancelled else { return false }
            return await passkeyManager.retryPasskeyRecovery()
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            PasskeyDiagnostics.failure("retryRecovery: rejected, account operation tracker is closed (account transition in progress)")
            operationTask.cancel()
            return false
        }
        defer { accountOperationTracker.end(operationToken) }
        let succeeded = await operationTask.value
        guard currentUserId == operationUserId else {
            PasskeyDiagnostics.failure("retryRecovery: user changed mid-operation")
            return false
        }
        if succeeded { await keyChanged() }
        return succeeded
    }

    /// Clears a skipped passkey recovery and runs it again, for the
    /// "unlock" actions of the sidebar, an error card and Settings. A key
    /// that must be set up or recovered by hand opens the onboarding sheet,
    /// as signing in does, and a key the passkey unlocked loads the
    /// account again.
    @discardableResult
    func reattemptPasskeyRecovery() async -> PasskeyRecoveryResult? {
        guard let operationUserId = currentUserId else { return nil }
        let operationTask = Task { [passkeyManager] in
            guard !Task.isCancelled else { return PasskeyRecoveryResult.recoveryFailed }
            return await passkeyManager.reenableRecoveryPrompt()
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            return nil
        }
        defer { accountOperationTracker.end(operationToken) }
        let result = await operationTask.value
        guard currentUserId == operationUserId else { return nil }
        switch result {
        case .manualSetupRequired:
            cloudSyncOnboardingMode = .setup
            showCloudSyncOnboarding = true
        case .manualRecoveryRequired:
            cloudSyncOnboardingMode = .recovery
            showCloudSyncOnboarding = true
        case .success, .newUserSetupDone:
            handleSignIn()
        default:
            break
        }
        return result
    }

    func startFreshWithNewKey() async -> PasskeyBackupResult {
        guard let operationUserId = currentUserId else { return .failure(.registerFailed) }
        let operationTask = Task { [passkeyManager] in
            guard !Task.isCancelled else { return PasskeyBackupResult.failure(.userCancelled) }
            return await passkeyManager.startFreshWithNewKey()
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            return .failure(.userCancelled)
        }
        defer { accountOperationTracker.end(operationToken) }
        let result = await operationTask.value
        guard currentUserId == operationUserId else { return .failure(.userCancelled) }
        if case .success = result { await keyChanged() }
        return result
    }

    func retryPasskeySetup() async -> PasskeyRecoveryResult {
        guard let operationUserId = currentUserId else { return .recoveryFailed }
        let operationTask = Task { [passkeyManager] in
            guard !Task.isCancelled else { return PasskeyRecoveryResult.recoveryFailed }
            return await passkeyManager.retryPasskeySetup()
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            return .recoveryFailed
        }
        defer { accountOperationTracker.end(operationToken) }
        let result = await operationTask.value
        guard currentUserId == operationUserId else { return .recoveryFailed }
        switch result {
        case .success, .newUserSetupDone:
            registerHeldKey(token: currentAccountOperationToken(userId: operationUserId), userId: operationUserId)
            await keyChanged()
        default:
            break
        }
        return result
    }

    @discardableResult
    func createPasskeyBackup() async -> PasskeyBackupResult {
        guard let operationUserId = currentUserId else { return .failure(.registerFailed) }
        let operationTask = Task { [passkeyManager] in
            guard !Task.isCancelled else { return PasskeyBackupResult.failure(.userCancelled) }
            return await passkeyManager.createPasskeyBackup()
        }
        guard let operationToken = accountOperationTracker.begin(task: operationTask) else {
            operationTask.cancel()
            return .failure(.userCancelled)
        }
        defer { accountOperationTracker.end(operationToken) }
        let result = await operationTask.value
        guard currentUserId == operationUserId else { return .failure(.userCancelled) }
        guard case .success = result else { return result }
        registerHeldKey(token: currentAccountOperationToken(userId: operationUserId), userId: operationUserId)
        return .success
    }

    /// The user set a key by hand: the account's data loads with it.
    /// The key is set, which already read the account again; the chat view
    /// only needs a chat to show.
    func resumeAfterManualKeySetup() {
        if currentChat == nil { createNewChat(focusInput: false) }
    }

    private func ensureCurrentAccount(_ userId: String) throws {
        try Task.checkCancellation()
        guard currentUserId == userId else { throw CancellationError() }
    }
}
