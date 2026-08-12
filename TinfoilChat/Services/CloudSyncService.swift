//
//  CloudSyncService.swift
//  TinfoilChat
//
//  Main service for orchestrating cloud synchronization
//

import Foundation
import Combine
import ClerkKit

// MARK: - Helper Functions

/// Create properly configured ISO8601DateFormatter that handles JavaScript's toISOString() format
private func createISO8601Formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

/// Parse ISO date string with fallback for different formats
private func parseISODate(_ dateString: String) -> Date? {
    // Try with fractional seconds first (JavaScript's toISOString() format)
    let formatterWithFraction = ISO8601DateFormatter()
    formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatterWithFraction.date(from: dateString) {
        return date
    }
    
    // Try without fractional seconds
    let formatterNoFraction = ISO8601DateFormatter()
    formatterNoFraction.formatOptions = [.withInternetDateTime]
    if let date = formatterNoFraction.date(from: dateString) {
        return date
    }
    
    return nil
}

/// One frozen upload attempt. The prepare function captures the chat
/// snapshot and returns this closure; every retry replays it, so the
/// bytes pushed to the enclave are identical across attempts and the
/// enclave can de-duplicate them into a single committed effect.
enum UploadAttemptOutcome: Equatable {
    case noUpload
    case uploaded
}

typealias UploadAttempt = @MainActor @Sendable () async throws -> UploadAttemptOutcome

enum UploadCoalescerError: Error {
    case requiredUploadNotPrepared
}

private enum UploadIterationOutcome {
    case noWork
    case uploaded
    case failed(Error)
}

/// Coalesces rapid upload requests per chat into single uploads with exponential backoff retry.
/// Uses a dirty-flag + worker-loop pattern to batch rapid successive writes.
///
/// The coalescer owns the idempotency key: it mints one per logical
/// write and calls prepare once to freeze that write's payload; `nil`
/// means there is nothing to upload (deleted/ineligible/streaming
/// chat). Retries re-run the returned attempt, never prepare — the
/// enclave's operation hash covers the plaintext, so a retry that
/// re-read a chat edited between attempts would replay different
/// bytes under the same key and fail with 409 IDEMPOTENCY_CONFLICT
/// instead of deduping.
actor UploadCoalescer {
    private struct ChatUploadState {
        var dirty: Bool = false
        var allowWhileStreaming: Bool = false
        var workerRunning: Bool = false
        var failureCount: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var throwingWaiters: [CheckedContinuation<Void, Error>] = []
    }

    private var states: [String: ChatUploadState] = [:]
    private var generation = 0
    private let prepareUpload: @Sendable (String, String, Bool) async throws -> UploadAttempt?
    private let waitBeforeRetry: @Sendable (Int) async -> Void

    init(
        prepareUpload: @escaping @Sendable (String, String, Bool) async throws -> UploadAttempt?,
        waitBeforeRetry: @escaping @Sendable (Int) async -> Void = { attempt in
            let delay = min(
                Constants.Sync.uploadBaseDelaySeconds * pow(2.0, Double(attempt)),
                Constants.Sync.uploadMaxDelaySeconds
            )
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) {
        self.prepareUpload = prepareUpload
        self.waitBeforeRetry = waitBeforeRetry
    }

    func enqueue(_ chatId: String, allowWhileStreaming: Bool = false) {
        var state = states[chatId] ?? ChatUploadState()
        state.dirty = true
        state.allowWhileStreaming = state.allowWhileStreaming || allowWhileStreaming
        states[chatId] = state

        if !state.workerRunning {
            states[chatId]?.workerRunning = true
            Task { await runWorker(chatId) }
        }
    }

    func waitForUpload(_ chatId: String) async {
        guard let state = states[chatId], state.workerRunning || state.dirty else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            states[chatId]?.waiters.append(continuation)
        }
    }

    func enqueueAndWait(
        _ chatId: String,
        allowWhileStreaming: Bool = false
    ) async throws {
        enqueue(chatId, allowWhileStreaming: allowWhileStreaming)

        guard let state = states[chatId], state.workerRunning || state.dirty else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            states[chatId]?.throwingWaiters.append(continuation)
        }
    }

    private func runWorker(_ chatId: String) async {
        let workerGeneration = generation
        var terminalError: Error?

        while states[chatId]?.dirty == true && workerGeneration == generation {
            states[chatId]?.dirty = false
            let allowWhileStreaming = states[chatId]?.allowWhileStreaming ?? false
            states[chatId]?.allowWhileStreaming = false

            // Mint one idempotency key per logical write. All HTTP
            // retries inside uploadWithRetry replay under the same
            // key so the enclave collapses them to a single
            // committed effect, even when a previous attempt
            // already committed and we lost the response.
            let idempotencyKey = newSyncEnclaveIdempotencyKey()
            let iterationOutcome = await uploadWithRetry(
                chatId,
                idempotencyKey: idempotencyKey,
                allowWhileStreaming: allowWhileStreaming,
                generation: workerGeneration
            )
            switch iterationOutcome {
            case .noWork:
                break
            case .uploaded:
                terminalError = nil
            case .failed(let iterationError):
                terminalError = iterationError
            }
        }
        guard workerGeneration == generation else { return }

        // Notify waiters and clean up in a single access
        let waiters = states[chatId]?.waiters ?? []
        for waiter in waiters {
            waiter.resume()
        }

        let throwingWaiters = states[chatId]?.throwingWaiters ?? []
        for waiter in throwingWaiters {
            if let terminalError {
                waiter.resume(throwing: terminalError)
            } else {
                waiter.resume()
            }
        }

        let failureCount = states[chatId]?.failureCount ?? 0
        if failureCount == 0 {
            states.removeValue(forKey: chatId)
        } else {
            states[chatId]?.workerRunning = false
            states[chatId]?.waiters = []
            states[chatId]?.throwingWaiters = []
        }
    }

    private func uploadWithRetry(
        _ chatId: String,
        idempotencyKey: String,
        allowWhileStreaming: Bool,
        generation workerGeneration: Int
    ) async -> UploadIterationOutcome {
        var lastError: Error?
        // Frozen on the first successful prepare so every retry replays
        // the exact payload the enclave may have already committed. Only
        // a failed prepare re-runs; a failed attempt never re-reads the
        // chat. Edits that land mid-write set `dirty` and go out as the
        // next logical write under a fresh key.
        var preparedAttempt: UploadAttempt?
        var prepared = false

        for attempt in 0...Constants.Sync.uploadMaxRetries {
            do {
                if !prepared {
                    preparedAttempt = try await prepareUpload(
                        chatId,
                        idempotencyKey,
                        allowWhileStreaming
                    )
                    prepared = true
                    guard workerGeneration == generation else {
                        return .failed(CancellationError())
                    }
                }
                if allowWhileStreaming && preparedAttempt == nil {
                    throw UploadCoalescerError.requiredUploadNotPrepared
                }
                let attemptOutcome = try await preparedAttempt?()
                guard workerGeneration == generation else {
                    return .failed(CancellationError())
                }
                states[chatId]?.failureCount = 0
                return attemptOutcome == .uploaded ? .uploaded : .noWork
            } catch {
                guard workerGeneration == generation else {
                    return .failed(CancellationError())
                }
                lastError = error
                let currentCount = states[chatId]?.failureCount ?? 0
                states[chatId]?.failureCount = currentCount + 1

                if attempt == Constants.Sync.uploadMaxRetries {
                    break
                }

                if case .retry = EnclaveErrorRecovery.decide(error).action {
                    await waitBeforeRetry(attempt)
                } else {
                    break
                }
                guard workerGeneration == generation else {
                    return .failed(CancellationError())
                }
            }
        }

        return .failed(lastError ?? UploadCoalescerError.requiredUploadNotPrepared)
    }

    func clear() {
        generation += 1
        let waiters = states.values.flatMap(\.waiters)
        let throwingWaiters = states.values.flatMap(\.throwingWaiters)
        states.removeAll()
        waiters.forEach { $0.resume() }
        throwingWaiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// Main service for managing cloud synchronization of chats
@MainActor
class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    private struct UploadAccount: Equatable {
        let generation: Int
        let userId: String
    }

    private struct PreparedChatUpload {
        let chat: StoredChat
        let expectedUpdatedAt: Date
        let idempotencyKey: String
        let account: UploadAccount
    }
    
    // MARK: - Published Properties
    @Published var isSyncing = false
    @Published var syncStatus: String = ""
    @Published var lastSyncDate: Date?
    @Published var syncErrors: [String] = []
    /// Chats whose upload is queued or in flight, so list rows can
    /// show a per-chat syncing indicator.
    @Published var pendingUploadChatIds: Set<String> = []
    /// Reference counts behind `pendingUploadChatIds`. Uploads of the same
    /// chat can overlap, and an earlier upload's completion may be scheduled
    /// after a later `backupChat` call; plain Set removal would then clear
    /// the indicator while the later upload is still in flight.
    private var pendingUploadCounts: [String: Int] = [:]
    
    // MARK: - Private Properties
    private lazy var uploadCoalescer: UploadCoalescer = {
        UploadCoalescer { [weak self] chatId, idempotencyKey, allowWhileStreaming in
            try await self?.doBackupChat(
                chatId,
                idempotencyKey: idempotencyKey,
                allowWhileStreaming: allowWhileStreaming
            )
        }
    }()
    private var streamingCallbacks: Set<String> = []
    /// Chats whose remote delete arrived while they were streaming
    /// locally; the local removal is deferred to stream end.
    private var deferredRemoteDeleteChatIds: Set<String> = []
    private var accountGeneration = 0
    private let cloudStorage = CloudStorageService.shared
    private let encryptionService = EncryptionService.shared
    private let deletedChatsTracker = DeletedChatsTracker.shared
    private let streamingTracker = StreamingTracker.shared
    private let revisionCheckpointStore = RevisionCheckpointStore()

    private init() {}

    /// The enclave is the source of truth for write authority: the local
    /// CEK may write only when it derives the key id the enclave currently
    /// has registered. The enclave never registers a key as a side effect
    /// of a write — without a `user_keys` row every push is rejected as a
    /// stale key — so when the remote has no key yet this gate registers
    /// the local CEK itself (empty remote) or defers the write until the
    /// legacy-migration path adopts the key (un-migrated legacy data). A
    /// local authorization hint is never sufficient on its own — another
    /// device may have rotated or reset the key, leaving this device's
    /// hint stale.
    private func canWriteToCloud() async -> Bool {
        let cek: Data
        do {
            cek = try EncryptionService.shared.getKeyBytesOrThrow()
        } catch {
            return false
        }

        let response: EnclaveKeyCurrentResponse
        do {
            response = try await SyncEnclaveAPI.keyCurrent()
        } catch {
            // Can't verify right now (offline / attestation / 5xx): defer the
            // write to a later sync cycle rather than risk writing under a
            // key the enclave no longer recognizes.
            return false
        }

        guard let remoteKeyId = response.keyId else {
            // No key is registered. Only ever bind a key the user has
            // actually committed and only while cloud sync is on. During
            // an activation ceremony the new key is staged in memory
            // only; a concurrent background write must not register it
            // before the ceremony finishes (a transient failure would
            // roll the client back while the server stays bound to the
            // discarded key).
            // The upload encrypts under the active in-memory CEK, but the
            // gate only ever binds the committed key. If a ceremony has
            // staged a different key in memory, registering the committed
            // key now would bind the account to a key the upload won't
            // use, and every push would then be rejected as a stale key.
            // Defer until the active key and the committed key agree (the
            // ceremony commits or rolls back) so the registered key and
            // the upload key are always the same.
            guard SettingsManager.shared.isCloudSyncEnabled,
                  let persistedBytes = LegacyBlobMigration.committedKeyIfActiveMatches()
            else {
                return false
            }
            let persistedB64 = dataToBase64(persistedBytes)
            if response.hasData {
                // Un-migrated legacy data with no registered key: the
                // controlplane rejects every push as a stale key until
                // the local CEK is adopted as the current key. Adopt it
                // here (created_via=recovery) so the write path
                // establishes its own precondition instead of deferring
                // forever while it waits for the out-of-band migration
                // kick.
                let adopted = await LegacyBlobMigration.adoptLocalKeyForMigration(
                    keyB64: persistedB64)
                if adopted {
                    SyncHealthStore.shared.reportKeyHealthy()
                }
                return adopted
            }
            return await registerKeyForEmptyRemote(keyB64: persistedB64)
        }

        let localKeyId: String
        do {
            localKeyId = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return false
        }

        if localKeyId == remoteKeyId {
            // The enclave just confirmed the local key is authoritative,
            // so any surfaced key problem is stale.
            SyncHealthStore.shared.reportKeyHealthy()
            return true
        }
        return false
    }

    private var emptyRemoteRegistration: Task<Bool, Never>?

    /// Bind the loaded primary CEK as the enclave's current key when the
    /// remote is completely empty. The controlplane rejects every push as
    /// a stale key until a user_keys row exists, and nothing else
    /// registers a manually generated/imported key on a brand-new
    /// account, so the write gate performs the registration itself. The
    /// AnyKey sentinel keeps this race-safe across devices: registration
    /// only succeeds while no key is registered, and a loss just defers
    /// the push until the next validation pass sees the winner's key.
    private func registerKeyForEmptyRemote(keyB64: String) async -> Bool {
        if let inFlight = emptyRemoteRegistration {
            return await inFlight.value
        }
        let task = Task<Bool, Never> {
            do {
                _ = try await SyncEnclaveAPI.registerKey(
                    EnclaveKeyRegisterRequest(
                        key: keyB64,
                        ifMatch: IfMatchSentinels.anyKey,
                        createdVia: SyncEnclaveCreatedVia.manual.rawValue,
                        idempotencyKey: newSyncEnclaveIdempotencyKey(),
                        initialBundle: nil
                    )
                )
                return true
            } catch {
                return false
            }
        }
        emptyRemoteRegistration = task
        let result = await task.value
        emptyRemoteRegistration = nil
        if result {
            // The local key just became the enclave's registered key, so
            // any surfaced key problem is stale.
            SyncHealthStore.shared.reportKeyHealthy()
        }
        return result
    }
    
    // MARK: - Initialization
    
    /// Initialize the sync service with auth token getter
    func initialize() async throws {
        // Initialize encryption service
        _ = try? await encryptionService.initialize()
        
        // Set up custom token getter for R2 storage that ensures Clerk is loaded
        let tokenGetter: SyncEnclaveClient.TokenGetter = { forceRefresh in
            do {
                // Check if Clerk has a publishable key
                guard await !Clerk.shared.publishableKey.isEmpty else {
                    return nil
                }
                
                // Ensure Clerk is loaded
                if await !Clerk.shared.isLoaded {
                    try await Clerk.shared.refreshClient()
                }
                
                // Get fresh token from session
                if let session = await Clerk.shared.session {
                    // Try to get a fresh token first (refresh if needed)
                    if let token = try? await session.getToken(.init(skipCache: forceRefresh)) {
                        return token
                    }
                    if forceRefresh { return nil }
                    // Fallback to last active token if refresh fails
                    if let tokenResource = session.lastActiveToken {
                        return tokenResource.jwt
                    }
                }
                
                return nil
            } catch {
                return nil
            }
        }
        
        // Set token getter for both R2 storage and ProfileSync
        await cloudStorage.setTokenGetter(tokenGetter)
        await ProfileSyncService.shared.setTokenGetter(tokenGetter)
        await ProjectStorageService.shared.setTokenGetter(tokenGetter)
        
    }
    
    // MARK: - Single Chat Backup
    
    /// Backup a single chat to the cloud, coalescing rapid successive calls
    func backupChat(
        _ chatId: String,
        ensureLatestUpload: Bool = false,
        allowWhileStreaming: Bool = false
    ) async {
        let generation = accountGeneration

        beginPendingUpload(chatId)
        await uploadCoalescer.enqueue(
            chatId,
            allowWhileStreaming: allowWhileStreaming
        )
        Task { [weak self] in
            await self?.uploadCoalescer.waitForUpload(chatId)
            self?.endPendingUpload(chatId, generation: generation)
        }

        if ensureLatestUpload {
            await uploadCoalescer.waitForUpload(chatId)
        }
    }

    func backupRecoveryChatAndWait(
        _ chatId: String,
        allowWhileStreaming: Bool
    ) async throws {
        let generation = accountGeneration
        beginPendingUpload(chatId)
        defer { endPendingUpload(chatId, generation: generation) }
        try await uploadCoalescer.enqueueAndWait(
            chatId,
            allowWhileStreaming: allowWhileStreaming
        )
        guard generation == accountGeneration else {
            throw CancellationError()
        }
    }

    func backupChatAndWait(_ chatId: String, requiredTurnId: String) async throws {
        let generation = accountGeneration
        guard let userId = await getCurrentUserId(),
              await cloudStorage.isAuthenticated(), await canWriteToCloud(),
              generation == accountGeneration
        else {
            throw SyncEnclaveError(message: "chat is not ready for cloud backup")
        }

        beginPendingUpload(chatId)
        defer { endPendingUpload(chatId, generation: generation) }
        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            guard generation == accountGeneration,
                  let chat = try? await EncryptedFileStorage.cloud.loadChat(
                      chatId: chatId,
                      userId: userId
                  ),
                  chat.messages.contains(where: {
                      $0.role == .user && $0.turnId == requiredTurnId
                  })
            else {
                throw SyncEnclaveError(message: "required chat turn is not ready for backup")
            }
            do {
                guard !deletedChatsTracker.isDeleted(chat.id) else {
                    throw CancellationError()
                }
                let result = try await cloudStorage.uploadChat(
                    StoredChat(from: chat, syncVersion: chat.syncVersion),
                    idempotencyKey: newSyncEnclaveIdempotencyKey()
                )
                guard generation == accountGeneration else {
                    throw SyncEnclaveError(message: "account changed during cloud backup")
                }
                let newVersion = result.syncVersion ?? chat.syncVersion + 1
                let fullySynced = try await EncryptedFileStorage.cloud.finalizeUploadIfFresh(
                    chatId: chat.id,
                    userId: userId,
                    expectedUpdatedAt: chat.updatedAt,
                    syncVersion: newVersion,
                    attachmentRewrites: result.rewrites.map {
                        (
                            clientId: $0.clientId,
                            serverId: $0.serverId,
                            encryptionKey: $0.encryptionKey
                        )
                    }
                )
                if fullySynced {
                    SyncHealthStore.shared.reportChatSynced(chat.id)
                }
                return
            } catch let error as SyncEnclaveError
                where EnclaveErrorRecovery.isVersionConflict(error) {
                guard let remote = try await cloudStorage.downloadChat(chatId),
                      let remoteChat = await convertStoredChat(remote)
                else {
                    throw error
                }
                let localClock = trustedChatClock(chat)
                let remoteClock = trustedChatClock(remoteChat)
                guard !SyncConflictResolver.remoteWins(
                    localClock: localClock,
                    remoteClock: remoteClock,
                    localUpdatedAt: chat.updatedAt,
                    remoteUpdatedAt: remoteChat.updatedAt
                ) else {
                    throw error
                }
                try await EncryptedFileStorage.cloud.updateSyncMetadata(
                    chatId: chatId,
                    userId: userId,
                    syncVersion: remote.syncVersion,
                    syncedAt: chat.syncedAt ?? Date(),
                    locallyModified: true
                )
            }
        }
        throw SyncEnclaveError(message: "required chat turn could not be backed up")
    }

    private func trustedChatClock(_ chat: Chat) -> EditClock? {
        guard let clock = chat.clock,
              let writer = chat.writer,
              chat.clockVersion == chat.syncVersion
        else {
            return nil
        }
        return EditClock(v: clock, w: writer)
    }

    private func beginPendingUpload(_ chatId: String) {
        pendingUploadCounts[chatId, default: 0] += 1
        pendingUploadChatIds.insert(chatId)
    }

    private func endPendingUpload(_ chatId: String, generation: Int) {
        guard generation == accountGeneration else { return }
        let remaining = (pendingUploadCounts[chatId] ?? 1) - 1
        if remaining <= 0 {
            pendingUploadCounts.removeValue(forKey: chatId)
            pendingUploadChatIds.remove(chatId)
        } else {
            pendingUploadCounts[chatId] = remaining
        }
    }

    /// Prepare one logical chat upload for the coalescer. Runs the
    /// eligibility checks, snapshots the chat, and returns a frozen
    /// attempt closure; the coalescer replays that closure on every
    /// retry so the enclave sees byte-identical plaintext under the
    /// same idempotency key. Re-reading the chat per retry instead
    /// would replay different bytes whenever the chat was edited
    /// between attempts, turning a committed-but-lost write into a
    /// 409 IDEMPOTENCY_CONFLICT. Returns nil when there is nothing
    /// to upload.
    private func doBackupChat(
        _ chatId: String,
        idempotencyKey: String,
        allowWhileStreaming: Bool
    ) async throws -> UploadAttempt? {
        let generation = accountGeneration
        guard let userId = await getCurrentUserId() else {
            if allowWhileStreaming {
                throw SyncEnclaveError(message: "recovery upload is not authenticated")
            }
            return nil
        }
        let account = UploadAccount(generation: generation, userId: userId)
        guard await cloudStorage.isAuthenticated() else {
            if allowWhileStreaming {
                throw SyncEnclaveError(message: "recovery upload is not authenticated")
            }
            return nil
        }
        guard await canWriteToCloud() else {
            if allowWhileStreaming {
                throw SyncEnclaveError(message: "recovery upload is not writable")
            }
            return nil
        }
        guard await isCurrentUploadAccount(account) else {
            if allowWhileStreaming { throw CancellationError() }
            return nil
        }

        // Check if chat is currently streaming
        if streamingTracker.isStreaming(chatId) && !allowWhileStreaming {
            // Check if we already have a callback registered for this chat
            if streamingCallbacks.contains(chatId) {
                return nil
            }
            
            
            // Mark that we have a callback registered
            streamingCallbacks.insert(chatId)
            
            // Register to sync once streaming ends
            streamingTracker.onStreamEnd(chatId) { [weak self] in
                Task { @MainActor in
                    guard self?.accountGeneration == generation else { return }
                    // Remove from tracking set
                    self?.streamingCallbacks.remove(chatId)
                    
                    
                    // Re-trigger the backup after streaming ends
                    await self?.backupChat(chatId)
                }
            }
            
            return nil
        }
        
        // Load chat from storage
        let chat: Chat
        do {
            guard let loadedChat = try await EncryptedFileStorage.cloud.loadChat(
                chatId: chatId,
                userId: userId
            ) else {
                throw ChatRecoverySyncError.chatMissing
            }
            chat = loadedChat
        } catch {
            if allowWhileStreaming { throw error }
            return nil // Chat might have been deleted
        }
        guard await isCurrentUploadAccount(account) else {
            if allowWhileStreaming { throw CancellationError() }
            return nil
        }
        
        
        // Don't sync blank, empty, decryption-failure, or local-only chats.
        // Local-only chats are the user's explicit choice to keep a chat off
        // the cloud, so they must never be uploaded.
        if chat.isBlankChat || chat.messages.isEmpty || chat.decryptionFailed
            || chat.dataCorrupted || chat.isLocalOnly {
            if allowWhileStreaming {
                throw UploadCoalescerError.requiredUploadNotPrepared
            }
            return nil
        }

        // Double-check streaming status right before upload
        if streamingTracker.isStreaming(chatId) && !allowWhileStreaming {
            return nil
        }

        let preparedUpload = PreparedChatUpload(
            chat: StoredChat(from: chat, syncVersion: chat.syncVersion),
            expectedUpdatedAt: chat.updatedAt,
            idempotencyKey: idempotencyKey,
            account: account
        )
        
        return { [weak self] in
            guard let self else { throw CancellationError() }
            guard await self.isCurrentUploadAccount(preparedUpload.account) else {
                throw CancellationError()
            }
            do {
                try await self.uploadAndMarkSynced(preparedUpload)
                return .uploaded
            } catch {
                guard await self.isCurrentUploadAccount(preparedUpload.account) else {
                    throw CancellationError()
                }
                let reconciledUpload = try await self.handleUploadFailure(
                    chatId: chatId,
                    error: error,
                    generation: preparedUpload.account.generation,
                    userId: preparedUpload.account.userId,
                    allowWhileStreaming: allowWhileStreaming
                )
                if allowWhileStreaming && !reconciledUpload {
                    throw error
                }
                return reconciledUpload ? .uploaded : .noUpload
            }
        }
    }

    /// Dispatch a sync-enclave error to the matching recovery
    /// surface. Re-throws transient cases so the coalescer can retry
    /// under the same idempotency key; reports non-transient cases
    /// into the sync-health
    /// store (which the settings status row and the sidebar badge
    /// render) so the chat stays locallyModified and is picked up
    /// on the next natural sync cycle without burning the retry
    /// budget.
    private func handleUploadFailure(
        chatId: String,
        error: Error,
        generation: Int,
        userId: String,
        allowWhileStreaming: Bool
    ) async throws -> Bool {
        let decision = EnclaveErrorRecovery.decide(error)
        switch decision.action {
        case .retry:
            throw error
        case .refreshCurrentKeyAndRetry:
            // Surface the stale key and leave the chat locallyModified
            // for a later sync pass after key recovery.
            SyncHealthStore.shared.reportKeyActionRequired(.keyMismatch)
            throw error
        case .surfaceConflict:
            return try await resolveConflictByPullingRemote(
                chatId,
                generation: generation,
                userId: userId,
                allowWhileStreaming: allowWhileStreaming
            )
        case .surfaceExistingDataUnderOtherKey:
            SyncHealthStore.shared.reportKeyActionRequired(.keyConflict)
            return false
        case .surfaceNotFound:
            SyncHealthStore.shared.reportChatSyncFailed(
                chatId,
                message: "This chat no longer exists in the cloud"
            )
            return false
        case .triggerRecoveryWizard:
            SyncHealthStore.shared.reportKeyActionRequired(.keyRecovery)
            return false
        case .blockAllSync(let reason):
            switch reason {
            case .attestationFailed:
                SyncHealthStore.shared.reportSyncPaused(.attestation)
            case .upgradeRequired:
                // 426: only an app update fixes this, so it gates as
                // actionRequired (sticky) rather than paused (self-healing).
                SyncHealthStore.shared.reportKeyActionRequired(.upgradeRequired)
            }
            return false
        case .migrateLegacyAndRetry:
            // The legacy re-seal runs out of band — on the next launch and right
            // after the key is adopted (see PasskeyManager) — both
            // gated on the key being the registered current key. The
            // upload remains dirty for a later sync cycle.
            throw error
        case .abort(let reason):
            if reason == .authenticationRequired {
                throw error
            }
            if reason == .forbidden {
                SyncHealthStore.shared.reportKeyActionRequired(.accountBlocked)
            } else {
                SyncHealthStore.shared.reportChatSyncFailed(
                    chatId,
                    message: "This chat couldn't be synced"
                )
            }
            return false
        }
    }

    /// Last-write-wins conflict resolution, arbitrated by content
    /// modification time so the winner is the same on every device.
    ///
    /// On a STALE_BLOB / SYNC_CONFLICT the server holds a version our
    /// upload was not based on. We download that remote row and compare
    /// its updatedAt against the local copy:
    ///
    /// - Remote is strictly newer (or we have no local copy): the
    ///   remote is the last write, so overwrite local with it.
    /// - Local is at least as fresh: OUR edit is the last write, so we
    ///   must not clobber unsynced local messages with the older remote
    ///   snapshot. Rebase the local row onto the server's current
    ///   version (so the next upload's CAS base matches) and re-upload,
    ///   letting local win instead of looping on STALE_BLOB forever.
    /// - Remote row is gone entirely (deleted on another device): the
    ///   remote deletion wins even over a dirty local copy — the local
    ///   row is removed and tombstoned so a racing upload can't
    ///   resurrect it, matching the revision drain's delete-wins policy.
    ///
    /// If the pull itself fails the chat stays locallyModified and the
    /// next sync cycle retries.
    private func resolveConflictByPullingRemote(
        _ chatId: String,
        generation: Int,
        userId: String,
        allowWhileStreaming: Bool
    ) async throws -> Bool {
        do {
            let remoteChat = try await cloudStorage.downloadChat(chatId)
            guard generation == accountGeneration else { return false }

            let localChat = try await EncryptedFileStorage.cloud.loadChat(
                chatId: chatId,
                userId: userId
            )
            guard generation == accountGeneration else { return false }

            // A remote delete that races the revision window still wins.
            // Remove the cloud-backed local row and let the next revision
            // drain replay the same tombstone idempotently.
            guard var downloadedChat = remoteChat else {
                _ = try await applyRemoteChatDelete(
                    chatId: chatId,
                    userId: userId,
                    generation: generation,
                    preserveNeverSynced: false
                )
                return false
            }
            if downloadedChat.modelType == nil {
                downloadedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }

            // A chat's edit clock is trusted only when it was maintained
            // at the row's current synced version; otherwise a
            // clock-unaware write intervened and we fall back to
            // updatedAt arbitration.
            func trustedClock(
                clock: Int?, writer: String?, clockVersion: Int?, syncVersion: Int
            ) -> EditClock? {
                guard let clock = clock, let writer = writer,
                      let clockVersion = clockVersion, clockVersion == syncVersion
                else { return nil }
                return EditClock(v: clock, w: writer)
            }

            let localClock = localChat.flatMap {
                trustedClock(
                    clock: $0.clock, writer: $0.writer,
                    clockVersion: $0.clockVersion, syncVersion: $0.syncVersion
                )
            }
            let remoteClock = trustedClock(
                clock: downloadedChat.clock, writer: downloadedChat.writer,
                clockVersion: downloadedChat.clockVersion,
                syncVersion: downloadedChat.syncVersion
            )

            let remoteWins = SyncConflictResolver.remoteWins(
                localClock: localClock,
                remoteClock: remoteClock,
                localUpdatedAt: localChat?.updatedAt,
                remoteUpdatedAt: downloadedChat.updatedAt
            )

            if !remoteWins {
                guard generation == accountGeneration else { return false }
                try await rebaseSyncVersion(
                    chatId,
                    version: downloadedChat.syncVersion,
                    generation: generation,
                    userId: userId
                )
                guard generation == accountGeneration else { return false }
                // Re-enqueue rather than wait: the coalescer worker will
                // pick up the dirty flag and re-run the upload with the
                // rebased version.
                await backupChat(
                    chatId,
                    allowWhileStreaming: allowWhileStreaming
                )
                return false
            }

            guard generation == accountGeneration else { return false }
            downloadedChat.syncedAt = Date()
            downloadedChat.locallyModified = false
            downloadedChat.projectLocallyModified = false
            let applied = await applyRemoteChatToStorage(
                downloadedChat,
                generation: generation,
                userId: userId,
                expectedLocalUpdatedAt: localChat?.updatedAt,
                allowLocallyModified: true
            )
            if applied {
                SyncHealthStore.shared.reportChatSynced(downloadedChat.id)
            }
            return false
        } catch {
            SyncHealthStore.shared.reportChatSyncFailed(
                chatId,
                message: "This chat couldn't be synced"
            )
            throw error
        }
    }

    // MARK: - Bulk Sync Operations

    /// Load full chat objects for every locally-modified or never-synced,
    /// non-local-only chat. Returns nil when the account generation moved
    /// on while loading.
    private func loadUnsyncedChats(userId: String, generation: Int) async -> [Chat]? {
        let unsyncedIds = (try? await EncryptedFileStorage.cloud.pendingChatIds(
            userId: userId
        )) ?? []
        guard generation == accountGeneration else { return nil }
        let unsyncedChats = (try? await EncryptedFileStorage.cloud.loadChats(
            chatIds: unsyncedIds,
            userId: userId
        )) ?? []
        guard generation == accountGeneration else { return nil }
        return unsyncedChats
    }

    /// Backup all unsynced chats
    private func backupUnsyncedChats() async -> SyncResult {
        let generation = accountGeneration
        var result = SyncResult()

        guard await canWriteToCloud() else {
            return result
        }
        guard let userId = await getCurrentUserId(),
              generation == accountGeneration else {
            return result
        }

        guard let unsyncedChats = await loadUnsyncedChats(
            userId: userId, generation: generation
        ) else { return result }
        
        
        // Filter out blank, empty, decryption failure, and streaming chats
        var chatsToSync: [Chat] = []
        for chat in unsyncedChats {
            if !chat.isBlankChat && !chat.messages.isEmpty
                && !chat.decryptionFailed && !chat.dataCorrupted {
                let isStreaming = streamingTracker.isStreaming(chat.id)
                if !isStreaming {
                    chatsToSync.append(chat)
                }
            }
        }
        
        
        // Upload chats sequentially to avoid connection exhaustion
        for chat in chatsToSync {
            guard generation == accountGeneration else { return result }
            // Skip if chat started streaming
            if streamingTracker.isStreaming(chat.id) {
                continue
            }

            do {
                try await uploadCoalescer.enqueueAndWait(chat.id)
                guard generation == accountGeneration else { return result }
                result = SyncResult(
                    uploaded: result.uploaded + 1,
                    downloaded: result.downloaded,
                    errors: result.errors
                )
            } catch {
                guard generation == accountGeneration else { return result }
                SyncHealthStore.shared.reportChatSyncFailed(
                    chat.id,
                    message: "This chat couldn't be synced"
                )
                result = SyncResult(
                    uploaded: result.uploaded,
                    downloaded: result.downloaded,
                    errors: result.errors + ["Failed to backup chat \(chat.id): \(error.localizedDescription)"]
                )
            }
        }
        
        return result
    }
    
    // MARK: - Pagination Support
    
    /// Load chats with pagination, combining local and remote sources
    func loadChatsWithPagination(
        limit: Int? = nil,
        continuationToken: String? = nil,
        loadLocal: Bool = true
    ) async -> PaginatedChatsResult {
        let generation = accountGeneration
        let pageLimit = limit ?? Constants.Pagination.chatsPerPage
        // If not authenticated, fall back to local-only pagination
        guard await cloudStorage.isAuthenticated() else {
            if loadLocal {
                let result = await loadLocalChatsWithPagination(
                    limit: pageLimit,
                    continuationToken: continuationToken
                )
                guard generation == accountGeneration else {
                    return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
                }
                return result
            }
            return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
        }
        guard generation == accountGeneration else {
            return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
        }
        
        do {
            // Fetch remote chats with pagination
            // includeContent: true to get the encrypted data directly
            let remoteList = try await cloudStorage.listChats(
                limit: pageLimit,
                continuationToken: continuationToken,
                includeContent: true
            )
            guard generation == accountGeneration else {
                return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
            }
            
            // Process remote chats in parallel
            var downloadedChats: [StoredChat] = []
            let chatsToProcess = remoteList.conversations
            
            // Initialize encryption if available; continue even without a key so we can at least
            // fetch metadata and store encrypted placeholders. Decryption will be attempted per-chat.
            _ = try? await encryptionService.initialize()
            guard generation == accountGeneration else {
                return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
            }

            // Process chats sequentially to avoid connection exhaustion
            for remoteChat in chatsToProcess {
                guard generation == accountGeneration else {
                    return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
                }
                // Skip recently deleted chats
                if deletedChatsTracker.isDeleted(remoteChat.id) {
                    continue
                }

                // Skip invalid chats (blank or without proper ID format)
                if !(await shouldProcessRemoteChat(remoteChat)) {
                    continue
                }

                guard let content = remoteChat.content else {
                    continue
                }

                if let decrypted = await decryptRemoteChat(remoteChat, content: content) {
                    guard generation == accountGeneration else {
                        return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
                    }
                    downloadedChats.append(decrypted.chat)
                } else {
                    guard generation == accountGeneration else {
                        return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
                    }
                    let placeholder = createEncryptedPlaceholder(remoteChat: remoteChat)
                    downloadedChats.append(placeholder)
                }
            }

            // Sort by latest activity (newest first), matching the server's
            // direction=desc list-status pagination.
            downloadedChats.sort { $0.updatedAt > $1.updatedAt }
            
            return PaginatedChatsResult(
                chats: downloadedChats,
                hasMore: remoteList.hasMore,
                nextToken: remoteList.nextContinuationToken
            )
            
        } catch {
            // On error, fall back to local if enabled
            if loadLocal {
                let result = await loadLocalChatsWithPagination(
                    limit: pageLimit,
                    continuationToken: continuationToken
                )
                guard generation == accountGeneration else {
                    return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
                }
                return result
            }
            return PaginatedChatsResult(chats: [], hasMore: false, nextToken: nil)
        }
    }
    
    /// Load local chats with pagination (fallback when offline or not authenticated)
    private func loadLocalChatsWithPagination(
        limit: Int,
        continuationToken: String?
    ) async -> PaginatedChatsResult {
        let allChats = await getAllChatsFromStorage()
        
        // Sort by latest activity (newest first), matching the server's
        // direction=desc list-status pagination.
        let sortedChats = allChats.sorted { $0.updatedAt > $1.updatedAt }
        
        // Parse continuation token as offset
        let offset = Int(continuationToken ?? "0") ?? 0
        
        // Safety check for bounds
        guard offset < sortedChats.count else {
            // We've gone past the end
            return PaginatedChatsResult(
                chats: [],
                hasMore: false,
                nextToken: nil
            )
        }
        
        // Get page of chats
        let pageEnd = min(offset + limit, sortedChats.count)
        let pageChats = Array(sortedChats[offset..<pageEnd])
        
        // Convert to StoredChat format
        let storedChats = pageChats.map { StoredChat(from: $0) }
        
        // Determine if there are more pages
        let hasMore = pageEnd < sortedChats.count
        let nextToken = hasMore ? String(pageEnd) : nil
        
        return PaginatedChatsResult(
            chats: storedChats,
            hasMore: hasMore,
            nextToken: nextToken
        )
    }
    
    /// Apply server metadata dates and set a default model on a chat
    /// the enclave already unsealed for us. `content` is the StoredChat
    /// JSON returned by `/v1/sync/pull` (format-version 2).
    /// Returns `nil` on a malformed body — callers create an encrypted
    /// placeholder in that case.
    struct DecryptedChatResult {
        var chat: StoredChat
    }

    private func decryptRemoteChat(
        _ remoteChat: RemoteChat,
        content: String
    ) async -> DecryptedChatResult? {
        guard let plaintextData = content.data(using: .utf8) else { return nil }

        do {
            var decryptedChat = try JSONDecoder().decode(StoredChat.self, from: plaintextData)
            decryptedChat.formatVersion = 2
            decryptedChat.projectId = remoteChat.projectId
            decryptedChat.projectLocallyModified = false

            // Prefer the blob's createdAt over the remote metadata.
            // StoredChat falls back to `Date()` on parse failure — when
            // the blob date is within the last few seconds it's almost
            // certainly that fallback, so prefer the server timestamp.
            let blobCreatedAt = decryptedChat.createdAt
            let blobLooksLikeFallback = abs(blobCreatedAt.timeIntervalSinceNow) < Constants.Sync.createdAtFallbackThresholdSeconds
            if blobLooksLikeFallback, let createdDate = parseISODate(remoteChat.createdAt) {
                decryptedChat.createdAt = createdDate
            }
            if let updatedDate = parseISODate(remoteChat.updatedAt) {
                decryptedChat.updatedAt = updatedDate
            }
            if decryptedChat.modelType == nil {
                decryptedChat.modelType = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }

            return DecryptedChatResult(chat: decryptedChat)
        } catch {
            return nil
        }
    }

    /// Create a placeholder for a chat the enclave declined to unseal
    /// (e.g. UNKNOWN_KEY). The ciphertext stays server-side; the local
    /// row is purely a "this chat exists but cannot be read" badge.
    private func createEncryptedPlaceholder(remoteChat: RemoteChat) -> StoredChat {
        StoredChat.encryptedPlaceholder(
            id: remoteChat.id,
            createdAt: parseISODate(remoteChat.createdAt) ?? Date(),
            updatedAt: parseISODate(remoteChat.updatedAt) ?? Date()
        )
    }
    
    /// Sync all chats (upload local changes, download remote changes)
    func syncAllChats() async -> SyncResult {
        let generation = accountGeneration
        guard !isSyncing else {
            return SyncResult()
        }
        // A 426 gate can only be lifted by updating the app; re-running
        // the cycle just burns requests against a server that already
        // refused this protocol version.
        if case .actionRequired(.upgradeRequired, _) = SyncHealthStore.shared.gate {
            return SyncResult()
        }

        isSyncing = true
        syncStatus = "Syncing..."
        defer {
            if generation == accountGeneration {
                isSyncing = false
                syncStatus = ""
                lastSyncDate = Date()
            }
        }

        let result = await doRevisionSync()
        guard generation == accountGeneration else { return SyncResult() }
        syncErrors = result.errors
        return result
    }

    private func doRevisionSync() async -> SyncResult {
        let generation = accountGeneration
        guard await cloudStorage.isAuthenticated(),
              let userId = await getCurrentUserId() else { return SyncResult() }
        do {
            let summary = try await SyncEnclaveAPI.revisionSummary()
            guard generation == accountGeneration else { return SyncResult() }
            guard DecimalRevision.isValid(summary.currentRevision),
                  DecimalRevision.isValid(summary.oldestReplayableRevision) else {
                throw RevisionSyncError.invalidRevision
            }

            let needsContentRepair = try await EncryptedFileStorage.cloud.needsContentRepair(
                userId: userId
            )
            guard generation == accountGeneration else { return SyncResult() }
            let checkpoint = revisionCheckpointStore.load(userId: userId)
            var result: SyncResult
            if needsContentRepair {
                result = try await reconcileRevisionSnapshot(
                    generation: generation,
                    userId: userId
                )
            } else if let checkpoint,
               DecimalRevision.compare(checkpoint, summary.oldestReplayableRevision) != .orderedAscending,
               DecimalRevision.compare(checkpoint, summary.currentRevision) != .orderedDescending {
                result = try await applyRevisionEvents(
                    afterRevision: checkpoint,
                    throughRevision: summary.currentRevision,
                    generation: generation,
                    userId: userId
                )
                guard generation == accountGeneration else { return SyncResult() }
                revisionCheckpointStore.save(summary.currentRevision, userId: userId)
            } else {
                result = try await reconcileRevisionSnapshot(
                    generation: generation,
                    userId: userId
                )
            }
            guard generation == accountGeneration else { return SyncResult() }

            let drained = try await drainDeleteIntents(userId: userId, generation: generation)
            guard generation == accountGeneration else { return SyncResult() }
            let uploads = await backupUnsyncedChats()
            return SyncResult(
                uploaded: uploads.uploaded,
                downloaded: result.downloaded,
                deleted: result.deleted + drained.deleted,
                errors: result.errors + drained.errors + uploads.errors
            )
        } catch {
            // Surface a force-upgrade refusal (HTTP 426) from any call in
            // the cycle so the gate check in syncAllChats stops the
            // periodic retries and the UI can prompt for an update.
            if case .blockAllSync(.upgradeRequired) = EnclaveErrorRecovery.decide(error).action {
                SyncHealthStore.shared.reportKeyActionRequired(.upgradeRequired)
            }
            return SyncResult(errors: ["Revision sync failed: \(error.localizedDescription)"])
        }
    }

    private func applyRevisionEvents(
        afterRevision: String,
        throughRevision: String,
        generation: Int,
        userId: String
    ) async throws -> SyncResult {
        if DecimalRevision.compare(afterRevision, throughRevision) == .orderedSame {
            return SyncResult()
        }
        var events: [EnclaveRevisionEvent] = []
        var cursor: String?
        repeat {
            let response = try await SyncEnclaveAPI.revisionEvents(
                EnclaveRevisionEventsRequest(
                    afterRevision: afterRevision,
                    throughRevision: throughRevision,
                    cursor: cursor,
                    limit: Constants.SyncEnclave.listStatusPageLimit
                )
            )
            guard generation == accountGeneration else { throw CancellationError() }
            events.append(contentsOf: response.events)
            cursor = response.nextCursor?.isEmpty == false ? response.nextCursor : nil
        } while cursor != nil

        let planned = try RevisionEventPlanner.orderedLatestEvents(
            events,
            afterRevision: afterRevision,
            throughRevision: throughRevision
        )
        guard planned.allSatisfy({ event in
            guard !event.id.isEmpty, parseISODate(event.updatedAt) != nil else { return false }
            if event.kind == .upsert {
                guard let etag = event.etag,
                      Int(etag).map({ $0 > 0 }) == true else { return false }
            }
            return true
        }) else {
            throw RevisionSyncError.invalidRevision
        }
        let local = try await EncryptedFileStorage.cloud.loadIndex(userId: userId)
        var localById: [String: ChatIndexEntry] = [:]
        for entry in local where localById[entry.id] == nil {
            localById[entry.id] = entry
        }
        let pendingDeleteIntents = try await EncryptedFileStorage.cloud.loadDeleteIntents(
            userId: userId
        )
        let pendingDeleteIds = Set(pendingDeleteIntents.map(\.chatId))
        let pullIds = planned.compactMap { event -> String? in
            guard event.kind == .upsert else { return nil }
            guard DeleteIntentPlanner.shouldApplyRemoteUpsert(
                chatId: event.id,
                pendingDeleteIds: pendingDeleteIds
            ) else { return nil }
            guard let entry = localById[event.id] else { return event.id }
            guard !entry.locallyModified else { return nil }
            return entry.decryptionFailed || String(entry.syncVersion) != event.etag
                ? event.id : nil
        }
        let pulled = try await cloudStorage.downloadChats(pullIds)
        var result = SyncResult()

        for event in planned {
            guard generation == accountGeneration else { throw CancellationError() }
            guard let eventUpdatedAt = parseISODate(event.updatedAt) else {
                throw RevisionSyncError.invalidRevision
            }
            switch event.kind {
            case .delete:
                let removed = try await applyRemoteChatDelete(
                    chatId: event.id,
                    userId: userId,
                    generation: generation,
                    preserveNeverSynced: false
                )
                if removed {
                    result = SyncResult(
                        downloaded: result.downloaded,
                        deleted: result.deleted + 1
                    )
                }
            case .upsert:
                guard DeleteIntentPlanner.shouldApplyRemoteUpsert(
                    chatId: event.id,
                    pendingDeleteIds: pendingDeleteIds
                ) else { continue }
                deletedChatsTracker.removeFromDeleted(event.id)
                if let remote = pulled[event.id] {
                    var chat = remote
                    chat.projectId = event.projectId
                    chat.projectLocallyModified = false
                    chat.updatedAt = eventUpdatedAt
                    chat.syncedAt = Date()
                    chat.locallyModified = false
                    let applyResult = await applyRemoteChatToStorageResult(
                        chat,
                        generation: generation,
                        userId: userId,
                        expectedLocalUpdatedAt: localById[event.id]?.updatedAt
                    )
                    if applyResult == .locallyModified { continue }
                    guard applyResult == .applied else {
                        throw RevisionSyncError.incompletePull
                    }
                    result = SyncResult(
                        downloaded: result.downloaded + 1,
                        deleted: result.deleted
                    )
                } else if let entry = localById[event.id],
                          SnapshotReconciliation.shouldApplyRemoteMetadata(
                            to: entry,
                            etag: event.etag,
                            projectId: event.projectId
                          ) {
                    guard let etag = event.etag, let syncVersion = Int(etag), syncVersion > 0 else {
                        throw RevisionSyncError.incompletePull
                    }
                    let applyResult = try await EncryptedFileStorage.cloud.applyRevisionMetadata(
                        chatId: event.id,
                        userId: userId,
                        projectId: event.projectId,
                        syncVersion: syncVersion
                    )
                    if applyResult == .locallyModified { continue }
                    guard applyResult == .applied else {
                        throw RevisionSyncError.incompletePull
                    }
                }
            }
        }
        return result
    }

    /// Apply a remote deletion locally, unless the chat is actively
    /// streaming — deleting the files mid-stream would race the stream's
    /// throttled saves, which recreate the chat with a stale sync
    /// version that later uploads as a zombie against a tombstoned row.
    /// Mirrors the upload path's deferral: tombstone immediately (so a
    /// racing upload can't resurrect the row) and remove the local files
    /// once the stream ends. Returns true when the chat was removed now.
    private func applyRemoteChatDelete(
        chatId: String,
        userId: String,
        generation: Int,
        preserveNeverSynced: Bool
    ) async throws -> Bool {
        guard streamingTracker.isStreaming(chatId) else {
            let removed = try await EncryptedFileStorage.cloud.deleteCloudChatForRevision(
                chatId: chatId,
                userId: userId,
                preserveNeverSynced: preserveNeverSynced
            )
            if removed {
                deletedChatsTracker.markAsDeleted(chatId)
            }
            return removed
        }

        deletedChatsTracker.markAsDeleted(chatId)
        guard !deferredRemoteDeleteChatIds.contains(chatId) else { return false }
        deferredRemoteDeleteChatIds.insert(chatId)
        streamingTracker.onStreamEnd(chatId) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.deferredRemoteDeleteChatIds.remove(chatId)
                guard self.accountGeneration == generation else { return }
                // A later upsert event (the chat was recreated remotely)
                // clears the tombstone; the deferred delete must then
                // stand down instead of removing the recreated chat.
                guard self.deletedChatsTracker.isDeleted(chatId) else { return }
                _ = try? await EncryptedFileStorage.cloud.deleteCloudChatForRevision(
                    chatId: chatId,
                    userId: userId,
                    preserveNeverSynced: preserveNeverSynced
                )
            }
        }
        return false
    }

    private func reconcileRevisionSnapshot(
        generation: Int,
        userId: String
    ) async throws -> SyncResult {
        var items: [EnclaveRevisionSnapshotItem] = []
        var cursor: String?
        var snapshotRevision: String?
        repeat {
            let response = try await SyncEnclaveAPI.revisionSnapshot(
                EnclaveRevisionSnapshotRequest(
                    cursor: cursor,
                    limit: Constants.SyncEnclave.listStatusPageLimit
                )
            )
            guard generation == accountGeneration else { throw CancellationError() }
            if let snapshotRevision, snapshotRevision != response.snapshotRevision {
                throw RevisionSyncError.snapshotChangedDuringPagination
            }
            snapshotRevision = response.snapshotRevision
            items.append(contentsOf: response.items)
            cursor = response.nextCursor?.isEmpty == false ? response.nextCursor : nil
        } while cursor != nil

        guard let snapshotRevision, DecimalRevision.isValid(snapshotRevision) else {
            throw RevisionSyncError.invalidRevision
        }
        guard items.allSatisfy({ item in
            !item.id.isEmpty && Int(item.etag).map({ $0 > 0 }) == true
                && parseISODate(item.updatedAt) != nil
        }) else {
            throw RevisionSyncError.invalidRevision
        }
        let local = try await EncryptedFileStorage.cloud.loadIndex(userId: userId)
        var localById: [String: ChatIndexEntry] = [:]
        for entry in local where localById[entry.id] == nil {
            localById[entry.id] = entry
        }
        let remoteIds = Set(items.map(\.id))
        let snapshotDeleteIntents = try await EncryptedFileStorage.cloud.loadDeleteIntents(
            userId: userId
        )
        let pendingDeleteIds = Set(snapshotDeleteIntents.map(\.chatId))
        for id in remoteIds where !pendingDeleteIds.contains(id) {
            deletedChatsTracker.removeFromDeleted(id)
        }
        for intent in DeleteIntentPlanner.confirmedAbsent(
            snapshotDeleteIntents,
            remoteIds: remoteIds
        ) {
            guard generation == accountGeneration else { throw CancellationError() }
            try await EncryptedFileStorage.cloud.removeDeleteIntent(
                chatId: intent.chatId,
                userId: userId
            )
        }
        var deleted = 0
        for id in SnapshotReconciliation.locallyRemovedIds(local: local, remoteIds: remoteIds) {
            guard generation == accountGeneration else { throw CancellationError() }
            if try await applyRemoteChatDelete(
                chatId: id,
                userId: userId,
                generation: generation,
                preserveNeverSynced: true
            ) {
                deleted += 1
            }
        }

        let missingContentIds = try await EncryptedFileStorage.cloud.missingChatContentIds(
            chatIds: local.map(\.id),
            userId: userId
        )
        // A chat with no content file and no remote row can never be
        // repaired: the snapshot has nothing to pull and the local file
        // is gone (e.g. a crash between file removal and the index
        // save). Prune its index entry, otherwise `needsContentRepair`
        // stays true and every reconcile fails with incompletePull —
        // which also starves delete intents and uploads forever.
        let unrecoverableIds = ChatContentIntegrity.unrecoverableIds(
            repairIds: missingContentIds,
            remoteIds: remoteIds,
            pendingDeleteIds: pendingDeleteIds
        )
        if !unrecoverableIds.isEmpty {
            guard generation == accountGeneration else { throw CancellationError() }
            _ = try await EncryptedFileStorage.cloud.pruneUnrecoverableIndexEntries(
                chatIds: unrecoverableIds,
                userId: userId
            )
        }
        let changed = SnapshotReconciliation.contentItems(
            local: local,
            remote: items.filter {
                DeleteIntentPlanner.shouldApplyRemoteUpsert(
                    chatId: $0.id,
                    pendingDeleteIds: pendingDeleteIds
                )
            },
            recentLimit: Constants.Pagination.chatsPerPage,
            missingContentIds: missingContentIds
        )
        var metadataOnly: [EnclaveRevisionSnapshotItem] = []
        let pullItems = changed.filter { item in
            guard let entry = localById[item.id] else { return true }
            if String(entry.syncVersion) == item.etag
                && !entry.decryptionFailed
                && !missingContentIds.contains(item.id) {
                metadataOnly.append(item)
                return false
            }
            return true
        }
        let pulled = try await cloudStorage.downloadChats(pullItems.map(\.id))
        var downloaded = 0
        for item in pullItems {
            guard generation == accountGeneration, var chat = pulled[item.id] else {
                throw RevisionSyncError.incompletePull
            }
            chat.projectId = item.projectId
            chat.projectLocallyModified = false
            guard let updatedAt = parseISODate(item.updatedAt) else {
                throw RevisionSyncError.invalidRevision
            }
            chat.updatedAt = updatedAt
            chat.syncedAt = Date()
            chat.locallyModified = false
            let applyResult = await applyRemoteChatToStorageResult(
                chat,
                generation: generation,
                userId: userId,
                expectedLocalUpdatedAt: localById[item.id]?.updatedAt,
                allowLocallyModified: missingContentIds.contains(item.id)
            )
            if applyResult == .locallyModified { continue }
            guard applyResult == .applied else {
                throw RevisionSyncError.incompletePull
            }
            downloaded += 1
        }
        for item in metadataOnly {
            guard let syncVersion = Int(item.etag), syncVersion > 0 else {
                throw RevisionSyncError.incompletePull
            }
            let applyResult = try await EncryptedFileStorage.cloud.applyRevisionMetadata(
                chatId: item.id,
                userId: userId,
                projectId: item.projectId,
                syncVersion: syncVersion
            )
            if applyResult == .locallyModified { continue }
            guard applyResult == .applied else {
                throw RevisionSyncError.incompletePull
            }
        }
        guard generation == accountGeneration else { throw CancellationError() }
        guard try await EncryptedFileStorage.cloud.completeContentRepairIfResolved(
            userId: userId,
            ignoring: pendingDeleteIds
        ) else {
            throw RevisionSyncError.incompletePull
        }
        guard generation == accountGeneration else { throw CancellationError() }
        revisionCheckpointStore.save(snapshotRevision, userId: userId)
        return SyncResult(downloaded: downloaded, deleted: deleted)
    }

    private struct DrainDeleteIntentsResult {
        var deleted = 0
        var errors: [String] = []
    }

    /// Push every staged delete intent to the enclave. A row-specific
    /// failure (conflict, malformed row, ...) is recorded and skipped so
    /// one poison intent never aborts the drain — the intent stays
    /// queued and is retried next cycle, and the cycle still reaches
    /// `backupUnsyncedChats`. Only failures that would hit every intent
    /// identically (network, auth, key problems, forced upgrade) stop
    /// the drain early.
    private func drainDeleteIntents(
        userId: String,
        generation: Int
    ) async throws -> DrainDeleteIntentsResult {
        let intents = try await EncryptedFileStorage.cloud.loadDeleteIntents(userId: userId)
        var result = DrainDeleteIntentsResult()
        for intent in intents.sorted(by: { $0.chatId < $1.chatId }) {
            guard generation == accountGeneration else { throw CancellationError() }
            if pendingUploadChatIds.contains(intent.chatId) {
                await uploadCoalescer.waitForUpload(intent.chatId)
                guard generation == accountGeneration else { throw CancellationError() }
            }
            do {
                try await cloudStorage.deleteChat(
                    intent.chatId,
                    idempotencyKey: intent.idempotencyKey
                )
            } catch {
                let decision = EnclaveErrorRecovery.decide(error)
                if case .surfaceNotFound = decision.action {
                    // The row is already gone remotely; the intent is
                    // satisfied, so fall through to the local cleanup.
                } else if DeleteIntentPlanner.isAccountWideFailure(decision.action) {
                    throw error
                } else {
                    result.errors.append(
                        "Failed to delete chat \(intent.chatId): \(error.localizedDescription)"
                    )
                    continue
                }
            }
            guard generation == accountGeneration,
                  await getCurrentUserId() == userId else {
                throw CancellationError()
            }
            _ = try await EncryptedFileStorage.cloud.deleteCloudChatForRevision(
                chatId: intent.chatId,
                userId: userId,
                preserveNeverSynced: false
            )
            try await EncryptedFileStorage.cloud.removeDeleteIntent(
                chatId: intent.chatId,
                userId: userId
            )
            deletedChatsTracker.markAsDeleted(intent.chatId)
            result.deleted += 1
        }
        return result
    }

    func smartSync() async -> SyncResult {
        await syncAllChats()
    }

    func smartSync(projectId: String?) async -> SyncResult {
        await syncAllChats()
    }

    func syncProjectChats(_ projectId: String) async -> SyncResult {
        await syncAllChats()
    }

    /// Clear cached sync status (call on logout / account switch).
    /// `userId` must be the signing-out user's id, resolved by the
    /// caller BEFORE the sign-out began: by the time this runs Clerk
    /// reports no user (sign-out) or already the next user (account
    /// switch), so resolving it here would clear the wrong user's
    /// revision checkpoint — or none at all.
    func clearSyncStatus(forUser userId: String?) async {
        accountGeneration += 1
        isSyncing = false
        syncStatus = ""
        lastSyncDate = nil
        streamingCallbacks.removeAll()
        deferredRemoteDeleteChatIds.removeAll()
        pendingUploadCounts.removeAll()
        pendingUploadChatIds.removeAll()
        await uploadCoalescer.clear()
        invalidateRevisionCheckpoint(forUser: userId)
        // Drop any in-flight key registration so the next signed-in user
        // never awaits a task started under the previous user's key.
        emptyRemoteRegistration?.cancel()
        emptyRemoteRegistration = nil
        await SyncEnclaveClient.shared.reset()
    }

    /// Drop the revision checkpoint for a user whose local cloud chat
    /// store was wiped. Every wipe path must call this: a surviving
    /// checkpoint makes the next sync take the incremental event-replay
    /// path against an empty local store, so chats older than the
    /// checkpoint would never be rehydrated (bootstrap never runs).
    func invalidateRevisionCheckpoint(forUser userId: String?) {
        guard let userId else { return }
        revisionCheckpointStore.clear(userId: userId)
    }

    // MARK: - Delete Operations
    
    /// Delete a chat from cloud storage
    /// Bulk-delete every chat the user owns from cloud storage. Returns the
    /// number of rows deleted. Callers are responsible for tombstoning local
    /// IDs only after this succeeds, mirroring the webapp's ordering.
    @discardableResult
    func deleteAllFromCloud() async throws -> Int {
        guard await cloudStorage.isAuthenticated() else {
            throw CloudStorageError.authenticationRequired
        }
        return try await cloudStorage.deleteAllChats()
    }

    func deleteFromCloud(_ chatId: String) async throws {
        let generation = accountGeneration
        guard let userId = await getCurrentUserId() else {
            throw CloudStorageError.authenticationRequired
        }
        deletedChatsTracker.markAsDeleted(chatId)
        let hasPendingUpload = pendingUploadChatIds.contains(chatId)
        guard let intent = try await EncryptedFileStorage.cloud.stageCloudDelete(
            chatId: chatId,
            userId: userId,
            idempotencyKey: newSyncEnclaveIdempotencyKey(),
            mayHaveInFlightUpload: hasPendingUpload
        ) else {
            return
        }
        if hasPendingUpload {
            await uploadCoalescer.waitForUpload(chatId)
        }
        guard generation == accountGeneration,
              await getCurrentUserId() == userId else {
            throw CancellationError()
        }
        
        // Don't attempt deletion if not authenticated
        guard await cloudStorage.isAuthenticated() else {
            return
        }
        
        do {
            try await cloudStorage.deleteChat(
                chatId,
                idempotencyKey: intent.idempotencyKey
            )
            guard generation == accountGeneration,
                  await getCurrentUserId() == userId else {
                throw CancellationError()
            }
            try await EncryptedFileStorage.cloud.removeDeleteIntent(
                chatId: chatId,
                userId: userId
            )
            
            SyncHealthStore.shared.reportChatSynced(chatId)
            
        } catch {
            syncErrors.append("This chat will be deleted from the cloud when sync resumes.")
        }
    }
    
    // MARK: - Storage Helpers
    
    private func getAllChatsFromStorage() async -> [Chat] {
        let userId = await getCurrentUserId()
        guard let userId = userId else { return [] }
        return (try? await EncryptedFileStorage.cloud.loadAllChats(userId: userId)) ?? []
    }

    private func convertStoredChat(_ storedChat: StoredChat) async -> Chat? {
        // For R2 data without modelType, set it from current config
        var chatToConvert = storedChat
        if chatToConvert.modelType == nil {
            chatToConvert.modelType = await MainActor.run {
                AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first
            }
        }

        // Convert to Chat - may return nil if models aren't available
        guard let chat = chatToConvert.toChat() else {
            #if DEBUG
            print("Warning: Could not convert StoredChat to Chat - no models available. Skipping chat \(chatToConvert.id)")
            #endif
            return nil
        }
        return chat
    }

    private func applyRemoteChatToStorage(
        _ storedChat: StoredChat,
        generation: Int,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool = false
    ) async -> Bool {
        await applyRemoteChatToStorageResult(
            storedChat,
            generation: generation,
            userId: userId,
            expectedLocalUpdatedAt: expectedLocalUpdatedAt,
            allowLocallyModified: allowLocallyModified
        ) == .applied
    }

    private func applyRemoteChatToStorageResult(
        _ storedChat: StoredChat,
        generation: Int,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool = false
    ) async -> RevisionApplyResult {
        guard generation == accountGeneration else { return .refused }
        guard let chat = await convertStoredChat(storedChat) else { return .refused }
        guard generation == accountGeneration else { return .refused }
        return (try? await EncryptedFileStorage.cloud.applyRemoteChatIfFreshResult(
            chat,
            userId: userId,
            expectedLocalUpdatedAt: expectedLocalUpdatedAt,
            allowLocallyModified: allowLocallyModified
        )) ?? .refused
    }

    private func uploadAndMarkSynced(_ upload: PreparedChatUpload) async throws {
        // Streaming is an eligibility check only while preparing. Once frozen,
        // this operation must finish while newer streaming edits stay dirty.
        try await uploadAndMarkSynced(
            upload.chat,
            expectedUpdatedAt: upload.expectedUpdatedAt,
            idempotencyKey: upload.idempotencyKey,
            account: upload.account
        )
    }

    /// Upload a chat to cloud and mark it as synced with the enclave's
    /// authoritative version (the new etag), or `chat.syncVersion + 1`
    /// when the enclave didn't return a parseable etag.
    private func uploadAndMarkSynced(
        _ chat: StoredChat,
        expectedUpdatedAt: Date,
        idempotencyKey: String,
        account: UploadAccount
    ) async throws {
        guard await isCurrentUploadAccount(account) else {
            throw CancellationError()
        }
        guard !deletedChatsTracker.isDeleted(chat.id) else {
            throw CancellationError()
        }
        let result = try await cloudStorage.uploadChat(
            chat,
            idempotencyKey: idempotencyKey
        )
        guard await isCurrentUploadAccount(account) else {
            throw CancellationError()
        }
        let newVersion = result.syncVersion ?? chat.syncVersion + 1
        let fullySynced = try await EncryptedFileStorage.cloud.finalizeUploadIfFresh(
            chatId: chat.id,
            userId: account.userId,
            expectedUpdatedAt: expectedUpdatedAt,
            syncVersion: newVersion,
            attachmentRewrites: result.rewrites.map {
                (
                    clientId: $0.clientId,
                    serverId: $0.serverId,
                    encryptionKey: $0.encryptionKey
                )
            }
        )
        guard await isCurrentUploadAccount(account) else {
            throw CancellationError()
        }
        if fullySynced {
            SyncHealthStore.shared.reportChatSynced(chat.id)
        }
    }

    private func isCurrentUploadAccount(_ account: UploadAccount) async -> Bool {
        guard account.generation == accountGeneration else { return false }
        return await getCurrentUserId() == account.userId
    }

    /// Rebase the local chat's sync version onto the server's current
    /// version while keeping it locallyModified, so the next upload's
    /// CAS base matches the enclave and the fresher local copy wins the
    /// last-write-wins race instead of looping on STALE_BLOB. This never
    /// clears the dirty flag, so the chat is still uploaded; the existing
    /// syncedAt is preserved.
    private func rebaseSyncVersion(
        _ chatId: String,
        version: Int,
        generation: Int,
        userId: String
    ) async throws {
        guard generation == accountGeneration else { return }
        guard let existing = try await EncryptedFileStorage.cloud.loadChat(
            chatId: chatId,
            userId: userId
        ) else { return }
        guard generation == accountGeneration else { return }
        try await EncryptedFileStorage.cloud.updateSyncMetadata(
            chatId: chatId,
            userId: userId,
            syncVersion: version,
            syncedAt: existing.syncedAt ?? Date(),
            locallyModified: true
        )
    }

    private func getCurrentUserId() async -> String? {
        // Get from Clerk
        if let user = Clerk.shared.user {
            return user.id
        }
        return nil
    }
    
    // MARK: - Validation Methods
    
    /// Determines if a remote chat should be processed/stored locally
    /// Returns false for clearly invalid chats that shouldn't be synced
    private func shouldProcessRemoteChat(_ remoteChat: RemoteChat) async -> Bool {
        // Check if it was recently deleted locally
        if deletedChatsTracker.isDeleted(remoteChat.id) {
            return false
        }
        // Do NOT filter out temporary IDs anymore. Some legacy/migrated chats
        // may have UUID-based IDs and must still be downloaded to avoid data loss.

        // Don't skip based on messageCount - for encrypted chats the server
        // may not accurately know the message count inside the encrypted blob.
        // Let decryption determine if the chat is valid.

        return true
    }
    
    // MARK: - Retry Decryption Methods

    /// Drop locally-stored placeholders for chats that previously failed to
    /// decrypt and re-pull them from the enclave. The legacy-blob migration
    /// runner is expected to have already rewrapped any server-side rows that
    /// were stuck on a key the client no longer has.
    func retryDecryptionWithNewKey(
        onProgress: ((Int, Int) -> Void)? = nil,
        batchSize: Int = 5
    ) async -> Int {
        let generation = accountGeneration
        guard let userId = await getCurrentUserId() else { return 0 }
        // The index alone knows which chats are placeholders; loading
        // and decrypting every chat file just to read the flag would
        // make each retry pass O(n) in disk and crypto work.
        let index = (try? await EncryptedFileStorage.cloud.loadIndex(userId: userId)) ?? []
        let failedChatIds = index.filter(\.decryptionFailed).map(\.id)
        if failedChatIds.isEmpty { return 0 }

        // Without keys every pull would come back empty; bail before
        // touching any placeholder so nothing is mistaken for an
        // upstream deletion.
        guard CEKEncoding.pullKeysIfAvailable() != nil else { return 0 }

        var recovered = 0
        for (offset, chatId) in failedChatIds.enumerated() {
            guard generation == accountGeneration else { break }
            // Re-pull each failed chat by id and replace the local
            // placeholder only once the enclave hands back plaintext.
            // A transient failure leaves the placeholder in place, so
            // chats never vanish from history because a retry pass ran
            // while the enclave was unreachable. Rows deleted upstream
            // drop their placeholder and stay gone; they must not be
            // reported as "recovered".
            do {
                if let fresh = try await cloudStorage.downloadChat(chatId) {
                    if fresh.decryptionFailed != true,
                       generation == accountGeneration {
                        var remoteChat = fresh
                        remoteChat.syncedAt = Date()
                        remoteChat.locallyModified = false
                        let expectedUpdatedAt = index.first {
                            $0.id == chatId
                        }?.updatedAt
                        let applied = await applyRemoteChatToStorage(
                            remoteChat,
                            generation: generation,
                            userId: userId,
                            expectedLocalUpdatedAt: expectedUpdatedAt
                        )
                        if applied {
                            recovered += 1
                        }
                    }
                } else if generation == accountGeneration {
                    guard let expectedUpdatedAt = index.first(where: {
                        $0.id == chatId
                    })?.updatedAt else {
                        continue
                    }
                    let removed = (try? await EncryptedFileStorage.cloud.deleteChatIfEvictable(
                        chatId: chatId,
                        userId: userId,
                        shouldEvict: {
                            $0.updatedAt == expectedUpdatedAt && $0.decryptionFailed
                        },
                        shouldEvictOnLoadError: { _ in false }
                    )) ?? false
                    guard generation == accountGeneration else { break }
                    if removed {
                        deletedChatsTracker.markAsDeleted(chatId)
                    }
                }
            } catch {
                // Keep the placeholder; a later pass retries.
            }

            if (offset + 1) % batchSize == 0 || offset == failedChatIds.count - 1 {
                onProgress?(offset + 1, failedChatIds.count)
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        return recovered
    }

    
    /// Re-encrypt all local chats with new key and upload to cloud
    func reencryptAndUploadChats() async -> (reencrypted: Int, uploaded: Int, errors: [String]) {
        let generation = accountGeneration
        var result = (reencrypted: 0, uploaded: 0, errors: [String]())
        guard let userId = await getCurrentUserId() else { return result }

        guard await canWriteToCloud() else {
            return result
        }
        
        // Get all local chats
        let allChats = (try? await EncryptedFileStorage.cloud.loadAllChats(
            userId: userId
        )) ?? []
        
        
        // Initialize encryption with new key
        do {
            _ = try await encryptionService.initialize()
        } catch {
            result.errors.append("Failed to initialize encryption: \(error)")
            return result
        }
        
        for chat in allChats {
            guard generation == accountGeneration else { break }
            // Skip blank and empty chats
            if chat.isBlankChat || chat.messages.isEmpty { continue }

            do {
                // Re-encrypt the chat with the new key by forcing a sync
                guard await cloudStorage.isAuthenticated() else { continue }
                
                var chatToReencrypt = chat
                chatToReencrypt.locallyModified = true
                
                // Save locally then upload (will be encrypted with new key)
                try await EncryptedFileStorage.cloud.saveChat(
                    chatToReencrypt,
                    userId: userId
                )
                guard generation == accountGeneration else { break }
                try await uploadCoalescer.enqueueAndWait(chatToReencrypt.id)
                
                result.uploaded += 1
                result.reencrypted += 1
                
            } catch {
                let errorMsg = "Failed to re-encrypt chat \(chat.id): \(error)"
                result.errors.append(errorMsg)
            }
        }
        
        
        return result
    }

}
