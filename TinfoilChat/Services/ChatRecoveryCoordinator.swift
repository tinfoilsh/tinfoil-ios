import Combine
import Foundation
@preconcurrency import OpenAI
import Security

func shouldRetryRecoveryResponse(statusCode: Int) -> Bool {
    (500..<600).contains(statusCode)
}

func shouldRetryRecoveryError(_ error: Error) -> Bool {
    guard case ChatRecoveryClientError.httpStatus(let statusCode) = error else {
        return false
    }
    return shouldRetryRecoveryResponse(statusCode: statusCode)
}

struct ChatRecoveryAttempt: Sendable {
    let chatId: String
    let turnId: String
    let userId: String
    let storage: ChatRecoveryStorage
    let sessionId: String
    let generation: Int
}

extension Notification.Name {
    static let chatRecoveryDidUpdate = Notification.Name("chatRecoveryDidUpdate")
}

enum ChatRecoveryNotificationKey {
    static let chatId = "chatId"
    static let userId = "userId"
    static let storage = "storage"
}

enum ChatRecoveryPhase {
    /// The proxy is still receiving the response from the model.
    case generating
    /// The response is complete and its final state is being restored.
    case restoring
}

/// Publishes the per-turn recovery phase observed by the coordinator.
@MainActor
final class ChatRecoveryPhaseTracker: ObservableObject {
    static let shared = ChatRecoveryPhaseTracker()

    @Published private(set) var phases: [String: ChatRecoveryPhase] = [:]

    private init() {}

    func phase(forTurnId turnId: String?) -> ChatRecoveryPhase {
        guard let turnId else { return .generating }
        return phases[turnId] ?? .generating
    }

    func setPhase(_ phase: ChatRecoveryPhase, turnId: String) {
        guard phases[turnId] != phase else { return }
        phases[turnId] = phase
    }

    func clear(turnId: String) {
        phases.removeValue(forKey: turnId)
    }

    func clearAll() {
        guard !phases.isEmpty else { return }
        phases.removeAll()
    }

    func isActive(turnId: String) -> Bool {
        phases[turnId] != nil
    }
}

func recoveryDraftHasVisibleContent(_ message: Message) -> Bool {
    message.hasVisibleAssistantContent
}

func recoveredResponseForPersistence(
    _ message: Message,
    timestamp: Date = Date()
) -> Message {
    var response = message
    response.timestamp = timestamp
    return response
}

func recoveredTitleMessages(
    titleState: Chat.TitleState,
    messages: [Message],
    response: Message,
    turnId: String
) -> [Message]? {
    guard titleState == .placeholder,
          messages.first(where: { $0.role == .user })?.turnId == turnId
    else {
        return nil
    }
    return mergingRecoveredResponse(
        response,
        into: messages,
        turnId: turnId
    )
}

func mergingRecoveredResponse(
    _ response: Message,
    into messages: [Message],
    turnId: String
) -> [Message] {
    var messages = messages
    if let existingIndex = messages.firstIndex(where: {
        $0.role == .assistant && $0.turnId == turnId
    }) {
        messages[existingIndex] = response
    } else if let userIndex = messages.lastIndex(where: {
        $0.role == .user && $0.turnId == turnId
    }) {
        messages.insert(response, at: messages.index(after: userIndex))
    } else {
        messages.append(response)
    }
    return messages
}

func recoveryResponsePayloadMatches(_ lhs: Message, _ rhs: Message) -> Bool {
    lhs.role == .assistant
        && lhs.role == rhs.role
        && lhs.turnId == rhs.turnId
        && lhs.content == rhs.content
        && (lhs.modelDisplayName == nil
            || rhs.modelDisplayName == nil
            || lhs.modelDisplayName == rhs.modelDisplayName)
        && lhs.thoughts == rhs.thoughts
        && lhs.isThinking == rhs.isThinking
        && lhs.webSearchState == rhs.webSearchState
        && lhs.urlFetches == rhs.urlFetches
        && lhs.toolCalls == rhs.toolCalls
        && (lhs.annotations ?? []) == (rhs.annotations ?? [])
        && lhs.webSearchBeforeThinking == rhs.webSearchBeforeThinking
}

func chatRecoveryRetryDelayNanoseconds(attempt: Int) -> UInt64 {
    var delay = Constants.ChatRecovery.retryBaseDelayNanoseconds
    for _ in 0..<max(0, attempt) {
        let (next, overflow) = delay.multipliedReportingOverflow(by: 2)
        if overflow || next >= Constants.ChatRecovery.retryMaxDelayNanoseconds {
            return Constants.ChatRecovery.retryMaxDelayNanoseconds
        }
        delay = next
    }
    return delay
}

func recoveryRetryDeadlineReached(
    _ envelope: PendingRecoveryEnvelope,
    now: Date = Date()
) -> Bool {
    (try? ChatRecoveryCrypto.isExpired(envelope, now: now)) ?? true
}

func registrationFailureDefinitelyDidNotPersist(_ error: Error) -> Bool {
    if let syncError = error as? ChatRecoverySyncError {
        switch syncError {
        case .chatMissing, .envelopeMissing, .pendingLimitReached, .conflict:
            return true
        }
    }
    if let enclaveError = error as? SyncEnclaveError {
        return EnclaveErrorRecovery.isVersionConflict(enclaveError)
    }
    return false
}

actor ChatRecoveryCoordinator {
    private struct ActiveRecoveryTask {
        let id: UUID
        let turnId: String
        let task: Task<Void, Never>
    }

    static let shared = ChatRecoveryCoordinator()

    private var accountGeneration = 0
    private var scanGeneration = 0
    private var cancelledTurns: Set<String> = []
    private var activeRecoveryTasks: [String: ActiveRecoveryTask] = [:]
    private var activeAccountId: String?
    private var activeScanGeneration: Int?

    func reset(accountId: String?) async {
        accountGeneration += 1
        scanGeneration += 1
        activeAccountId = accountId
        cancelledTurns.removeAll()
        activeRecoveryTasks.values.forEach { $0.task.cancel() }
        activeRecoveryTasks.removeAll()
        activeScanGeneration = nil
        let generation = accountGeneration
        await MainActor.run {
            ChatRecoveryPhaseTracker.shared.clearAll()
            ChatRecoveryDraftStore.shared.reset(generation: generation)
        }
    }

    func begin(
        chatId: String,
        turnId: String,
        userId: String,
        storage: ChatRecoveryStorage
    ) async throws -> ChatRecoveryAttempt {
        if activeAccountId != userId {
            await reset(accountId: userId)
        }
        cancelledTurns.remove(turnKey(
            chatId: chatId,
            turnId: turnId,
            storage: storage
        ))
        await MainActor.run {
            ChatRecoveryDraftStore.shared.allow(
                chatId: chatId,
                turnId: turnId
            )
        }
        return ChatRecoveryAttempt(
            chatId: chatId,
            turnId: turnId,
            userId: userId,
            storage: storage,
            sessionId: try randomSessionId(),
            generation: accountGeneration
        )
    }

    func registerLocally(
        attempt: ChatRecoveryAttempt,
        token: ChatRecoveryTokenPayload
    ) async throws -> (
        envelope: PendingRecoveryEnvelope,
        metadata: ChatRecoveryLocalMutationResult
    ) {
        guard liveAttemptIsCurrent(attempt) else {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            throw CancellationError()
        }
        let envelope: PendingRecoveryEnvelope
        do {
            let cek: Data
            switch attempt.storage {
            case .cloud:
                cek = try EncryptionService.shared.getKeyBytesOrThrow()
            case .local:
                cek = try await DeviceEncryptionService.shared.getKeyBytesOrThrow()
            }
            envelope = try ChatRecoveryCrypto.encrypt(
                cek: cek,
                userId: attempt.userId,
                chatId: attempt.chatId,
                turnId: attempt.turnId,
                sessionId: attempt.sessionId,
                recoveryToken: token
            )
        } catch {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            throw error
        }
        let metadata: ChatRecoveryLocalMutationResult
        do {
            metadata = try await ChatRecoverySync.shared.mutateLocally(
                chatId: attempt.chatId,
                userId: attempt.userId,
                storage: attempt.storage,
                mutation: .add(envelope)
            )
        } catch {
            let containsEnvelope = try? await attempt.storage.fileStorage.containsPendingRecovery(
                chatId: attempt.chatId,
                userId: attempt.userId,
                envelope: envelope
            )
            if containsEnvelope == false {
                try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            }
            throw error
        }
        guard liveAttemptIsCurrent(attempt) else {
            let cancelled = await cancelLocally(attempt: attempt, response: nil)
            if cancelled != nil, attempt.storage == .cloud {
                await CloudSyncService.shared.backupChat(
                    attempt.chatId,
                    allowWhileStreaming: true
                )
            }
            throw CancellationError()
        }
        return (envelope, metadata)
    }

    func completeLocally(
        attempt: ChatRecoveryAttempt,
        envelope: PendingRecoveryEnvelope,
        response: Message,
        title: String?,
        titleState: Chat.TitleState?
    ) async throws -> ChatRecoveryLocalMutationResult {
        guard liveAttemptIsCurrent(attempt) else {
            let cancelled = await cancelLocally(attempt: attempt, response: response)
            if cancelled != nil, attempt.storage == .cloud {
                await CloudSyncService.shared.backupChat(
                    attempt.chatId,
                    allowWhileStreaming: true
                )
            }
            throw CancellationError()
        }
        let metadata = try await ChatRecoverySync.shared.mutateLocally(
            chatId: attempt.chatId,
            userId: attempt.userId,
            storage: attempt.storage,
            mutation: .complete(
                envelope: envelope,
                response: response,
                title: title,
                titleState: titleState
            )
        )
        await MainActor.run {
            ChatRecoveryDraftStore.shared.clear(
                chatId: attempt.chatId,
                turnId: attempt.turnId
            )
        }
        if attempt.storage == .local {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
        }
        return metadata
    }

    func cancelLocally(
        attempt: ChatRecoveryAttempt,
        response: Message?
    ) async -> ChatRecoveryLocalMutationResult? {
        markCancelled(attempt: attempt)
        let shouldClearPhase = !hasActiveRecovery(turnId: attempt.turnId)
        await MainActor.run {
            if shouldClearPhase {
                ChatRecoveryPhaseTracker.shared.clear(turnId: attempt.turnId)
            }
            ChatRecoveryDraftStore.shared.discard(
                chatId: attempt.chatId,
                turnId: attempt.turnId
            )
        }
        do {
            let metadata = try await ChatRecoverySync.shared.mutateLocally(
                chatId: attempt.chatId,
                userId: attempt.userId,
                storage: attempt.storage,
                mutation: .cancel(turnId: attempt.turnId, response: response)
            )
            if attempt.storage == .local {
                try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            }
            return metadata
        } catch {
            return nil
        }
    }

    func markCancelled(attempt: ChatRecoveryAttempt) {
        cancelledTurns.insert(turnKey(
            chatId: attempt.chatId,
            turnId: attempt.turnId,
            storage: attempt.storage
        ))
    }

    func liveAttemptIsCurrent(_ attempt: ChatRecoveryAttempt) -> Bool {
        let key = turnKey(
            chatId: attempt.chatId,
            turnId: attempt.turnId,
            storage: attempt.storage
        )
        return !cancelledTurns.contains(key)
            && attempt.generation == accountGeneration
            && activeAccountId == attempt.userId
    }

    func deleteSession(attempt: ChatRecoveryAttempt) async {
        try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
    }

    func cancelRecoveredTurn(
        chatId: String,
        envelope: PendingRecoveryEnvelope,
        userId: String,
        storage: ChatRecoveryStorage
    ) async {
        guard activeAccountId == userId else { return }
        let key = turnKey(
            chatId: chatId,
            turnId: envelope.turnId,
            storage: storage
        )
        cancelledTurns.insert(key)
        defer { cancelledTurns.remove(key) }
        let recoveryTask = activeRecoveryTasks[key]?.task
        recoveryTask?.cancel()
        let shouldClearPhase = !hasActiveRecovery(
            turnId: envelope.turnId,
            excluding: key
        )
        await MainActor.run {
            if shouldClearPhase {
                ChatRecoveryPhaseTracker.shared.clear(turnId: envelope.turnId)
            }
            ChatRecoveryDraftStore.shared.discard(
                chatId: chatId,
                turnId: envelope.turnId
            )
        }
        await recoveryTask?.value
        let openedEnvelope = try? await openEnvelope(
            envelope,
            chatId: chatId,
            userId: userId,
            storage: storage
        )
        let sessionId = openedEnvelope?.payload.sessionId
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                storage: storage,
                mutation: .cancel(turnId: envelope.turnId, response: nil)
            )
        } catch ChatRecoverySyncError.envelopeMissing {
            if storage == .cloud {
                do {
                    try await ChatRecoverySync.shared.refreshFromRemote(
                        chatId: chatId,
                        userId: userId
                    )
                } catch {
                    return
                }
            }
        } catch {
            return
        }
        if let sessionId {
            try? await ChatRecoveryClient.shared.delete(sessionId: sessionId)
        }
        postRecoveryUpdate(
            chatId: chatId,
            userId: userId,
            storage: storage
        )
    }

    func scan(
        userId: String,
        storages: [ChatRecoveryStorage],
        replacingActiveScan: Bool,
        onProgress: @escaping @Sendable () async -> Void
    ) async {
        if activeAccountId != userId {
            await reset(accountId: userId)
        }
        guard replacingActiveScan || activeScanGeneration == nil else { return }
        scanGeneration += 1
        let currentScanGeneration = scanGeneration
        activeScanGeneration = currentScanGeneration
        defer {
            if activeScanGeneration == currentScanGeneration {
                activeScanGeneration = nil
            }
        }
        let currentAccountGeneration = accountGeneration
        await MainActor.run {
            ChatRecoveryDraftStore.shared.beginScan(
                generation: currentScanGeneration
            )
        }
        guard scanIsCurrent(
            accountGeneration: currentAccountGeneration,
            scanGeneration: currentScanGeneration,
            userId: userId
        ) else {
            return
        }
        var work: [(String, PendingRecoveryEnvelope, ChatRecoveryStorage)] = []
        for storage in storages {
            guard scanIsCurrent(
                accountGeneration: currentAccountGeneration,
                scanGeneration: currentScanGeneration,
                userId: userId
            ) else {
                return
            }
            let storedChats = (try? await storage.fileStorage.loadChatsWithPendingRecoveries(
                userId: userId
            )) ?? []
            work.append(contentsOf: storedChats.flatMap { chat in
                (chat.pendingRecoveries ?? []).map { (chat.id, $0, storage) }
            })
        }
        guard !work.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            for _ in 0..<min(Constants.ChatRecovery.maxConcurrentScans, work.count) {
                guard !Task.isCancelled else { return }
                if let item = iterator.next() {
                    group.addTask {
                        await self.performRecovery(
                            chatId: item.0,
                            envelope: item.1,
                            userId: userId,
                            accountGeneration: currentAccountGeneration,
                            scanGeneration: currentScanGeneration,
                            storage: item.2,
                            onProgress: onProgress
                        )
                    }
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { return }
                if let item = iterator.next() {
                    group.addTask {
                        await self.performRecovery(
                            chatId: item.0,
                            envelope: item.1,
                            userId: userId,
                            accountGeneration: currentAccountGeneration,
                            scanGeneration: currentScanGeneration,
                            storage: item.2,
                            onProgress: onProgress
                        )
                    }
                }
            }
        }
    }

    private func performRecovery(
        chatId: String,
        envelope: PendingRecoveryEnvelope,
        userId: String,
        accountGeneration: Int,
        scanGeneration: Int,
        storage: ChatRecoveryStorage,
        onProgress: @escaping @Sendable () async -> Void
    ) async {
        let key = turnKey(
            chatId: chatId,
            turnId: envelope.turnId,
            storage: storage
        )
        let id = UUID()
        let task = Task {
            await recover(
                chatId: chatId,
                envelope: envelope,
                userId: userId,
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                storage: storage,
                onProgress: onProgress
            )
        }
        activeRecoveryTasks[key] = ActiveRecoveryTask(
            id: id,
            turnId: envelope.turnId,
            task: task
        )
        await MainActor.run {
            ChatRecoveryPhaseTracker.shared.setPhase(
                .generating,
                turnId: envelope.turnId
            )
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if activeRecoveryTasks[key]?.id == id {
            activeRecoveryTasks.removeValue(forKey: key)
            if !hasActiveRecovery(turnId: envelope.turnId) {
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.clear(turnId: envelope.turnId)
                }
            }
        }
    }

    private func recover(
        chatId: String,
        envelope originalEnvelope: PendingRecoveryEnvelope,
        userId: String,
        accountGeneration: Int,
        scanGeneration: Int,
        storage: ChatRecoveryStorage,
        onProgress: @escaping @Sendable () async -> Void
    ) async {
        guard scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ),
              !(await isChatStreaming(chatId))
        else {
            return
        }
        var envelope = originalEnvelope
        let payload: ChatRecoveryEnvelopePayload
        do {
            if try ChatRecoveryCrypto.isExpired(envelope) {
                throw ChatRecoveryCryptoError.expired
            }
            let opened = try await openEnvelope(
                envelope,
                chatId: chatId,
                userId: userId,
                storage: storage
            )
            payload = opened.payload
            if storage == .cloud && opened.usedHistoricalKey {
                guard scanIsCurrent(
                    accountGeneration: accountGeneration,
                    scanGeneration: scanGeneration,
                    userId: userId
                ) else {
                    return
                }
                let currentCEK = try EncryptionService.shared.getKeyBytesOrThrow()
                let rewrapped = try ChatRecoveryCrypto.rewrap(
                    envelope: envelope,
                    userId: userId,
                    chatId: chatId,
                    oldCEK: opened.cek,
                    newCEK: currentCEK
                )
                try await ChatRecoverySync.shared.mutate(
                    chatId: chatId,
                    userId: userId,
                    storage: storage,
                    mutation: .replace(old: envelope, new: rewrapped)
                )
                guard scanIsCurrent(
                    accountGeneration: accountGeneration,
                    scanGeneration: scanGeneration,
                    userId: userId
                ) else {
                    return
                }
                envelope = rewrapped
                postRecoveryUpdate(
                    chatId: chatId,
                    userId: userId,
                    storage: storage
                )
            }
        } catch ChatRecoveryCryptoError.expired {
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            let cleanupDate = try? ChatRecoveryCrypto.dateImmediatelyBeforeExpiry(
                envelope
            )
            let sessionId: String?
            if let cleanupDate,
               let opened = try? await openEnvelope(
                   envelope,
                   chatId: chatId,
                   userId: userId,
                   storage: storage,
                   now: cleanupDate
               ) {
                sessionId = opened.payload.sessionId
            } else {
                sessionId = nil
            }
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            await removeTerminal(
                chatId: chatId,
                envelope: envelope,
                userId: userId,
                sessionId: sessionId,
                storage: storage,
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration
            )
            return
        } catch ChatRecoveryCryptoError.invalidEnvelope,
                ChatRecoveryCryptoError.decryptionFailed {
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            await removeTerminal(
                chatId: chatId,
                envelope: envelope,
                userId: userId,
                sessionId: nil,
                storage: storage,
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration
            )
            return
        } catch {
            return
        }

        guard scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ) else {
            return
        }
        let turnId = envelope.turnId
        var locallyRecoveredResponse: Message?
        var generatedTitle: String?
        do {
            let initialStatus = try await ChatRecoveryClient.shared.status(
                sessionId: payload.sessionId
            )
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            await onProgress()
            var highestPersistedBytes = initialStatus.persistedBytes
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            switch initialStatus.state {
            case .processing:
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.setPhase(.generating, turnId: turnId)
                }
            case .failed, .missing:
                await removeTerminal(
                    chatId: chatId,
                    envelope: envelope,
                    userId: userId,
                    sessionId: payload.sessionId,
                    storage: storage,
                    accountGeneration: accountGeneration,
                    scanGeneration: scanGeneration
                )
                return
            case .complete:
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.setPhase(.restoring, turnId: turnId)
                }
            }
            guard let token = payload.recoveryToken.fields else { return }
            let key = turnKey(
                chatId: chatId,
                turnId: envelope.turnId,
                storage: storage
            )
            let persistedCheckpoint = (
                try? await storage.fileStorage.loadChat(
                    chatId: chatId,
                    userId: userId
                )
            )?.messages.first(where: {
                $0.role == .assistant && $0.turnId == envelope.turnId
            })
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            var response: Message?
            for attempt in 0... {
                if recoveryRetryDeadlineReached(envelope) {
                    await removeTerminal(
                        chatId: chatId,
                        envelope: envelope,
                        userId: userId,
                        sessionId: payload.sessionId,
                        storage: storage,
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration
                    )
                    return
                }
                do {
                    await MainActor.run {
                        ChatRecoveryDraftStore.shared.beginReplayAttempt(
                            chatId: chatId,
                            turnId: turnId,
                            sessionId: payload.sessionId,
                            fallbackCheckpoint: persistedCheckpoint
                        )
                    }
                    let recovered = try await ChatRecoveryClient.shared.fetch(
                        sessionId: payload.sessionId,
                        token: token
                    )
                    guard scanIsCurrent(
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ) else {
                        return
                    }
                    if !(200..<300).contains(recovered.statusCode) {
                        if shouldRetryRecoveryResponse(statusCode: recovered.statusCode) {
                            if attempt < Constants.ChatRecovery.maxResponseRetryAttempts {
                                try await waitForRecoveryRetry(attempt: attempt)
                                continue
                            }
                            throw ChatRecoveryClientError.httpStatus(recovered.statusCode)
                        }
                        for try await _ in recovered.stream {}
                        guard scanIsCurrent(
                            accountGeneration: accountGeneration,
                            scanGeneration: scanGeneration,
                            userId: userId
                        ),
                              !cancelledTurns.contains(key),
                              !(await isChatStreaming(chatId))
                        else {
                            return
                        }
                        await removeTerminal(
                            chatId: chatId,
                            envelope: envelope,
                            userId: userId,
                            sessionId: payload.sessionId,
                            storage: storage,
                            accountGeneration: accountGeneration,
                            scanGeneration: scanGeneration
                        )
                        return
                    }
                    let recoveredResponse = try await reconstructMessage(
                        stream: recovered.stream,
                        modelDisplayName: persistedCheckpoint?.modelDisplayName,
                        chatId: chatId,
                        turnId: envelope.turnId,
                        sessionId: payload.sessionId,
                        userId: userId,
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        storage: storage,
                        onProgress: onProgress
                    )
                    guard scanIsCurrent(
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ),
                          !cancelledTurns.contains(key),
                          !(await isChatStreaming(chatId))
                    else {
                        return
                    }
                    let finalStatus = try await ChatRecoveryClient.shared.status(
                        sessionId: payload.sessionId
                    )
                    guard scanIsCurrent(
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ) else {
                        return
                    }
                    if finalStatus.persistedBytes > highestPersistedBytes {
                        highestPersistedBytes = finalStatus.persistedBytes
                        await onProgress()
                    }
                    guard scanIsCurrent(
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ) else {
                        return
                    }
                    switch finalStatus.state {
                    case .processing:
                        await MainActor.run {
                            ChatRecoveryPhaseTracker.shared.setPhase(
                                .generating,
                                turnId: turnId
                            )
                        }
                        try await waitForRecoveryRetry(attempt: attempt)
                        continue
                    case .failed, .missing:
                        await removeTerminal(
                            chatId: chatId,
                            envelope: envelope,
                            userId: userId,
                            sessionId: payload.sessionId,
                            storage: storage,
                            accountGeneration: accountGeneration,
                            scanGeneration: scanGeneration
                        )
                        return
                    case .complete:
                        await MainActor.run {
                            ChatRecoveryPhaseTracker.shared.setPhase(
                                .restoring,
                                turnId: turnId
                            )
                        }
                    }
                    let encryptedByteCount = await recovered.encryptedByteCount()
                    guard scanIsCurrent(
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ) else {
                        return
                    }
                    if encryptedByteCount < finalStatus.persistedBytes {
                        try await waitForRecoveryRetry(attempt: attempt)
                        continue
                    }
                    response = recoveredResponse
                    break
                } catch {
                    let chatIsStreaming = await isChatStreaming(chatId)
                    guard scanIsCurrent(
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ),
                          !cancelledTurns.contains(key),
                          !chatIsStreaming
                    else {
                        return
                    }
                    if shouldRetryRecoveryError(error) {
                        if attempt < Constants.ChatRecovery.maxResponseRetryAttempts {
                            try await waitForRecoveryRetry(attempt: attempt)
                            continue
                        }
                    }
                    guard let retryStatus = try? await ChatRecoveryClient.shared.status(
                        sessionId: payload.sessionId
                    )
                    else {
                        return
                    }
                    if retryStatus.persistedBytes > highestPersistedBytes {
                        highestPersistedBytes = retryStatus.persistedBytes
                        await onProgress()
                    }
                    switch retryStatus.state {
                    case .processing, .complete:
                        try await waitForRecoveryRetry(attempt: attempt)
                        continue
                    case .failed, .missing:
                        await removeTerminal(
                            chatId: chatId,
                            envelope: envelope,
                            userId: userId,
                            sessionId: payload.sessionId,
                            storage: storage,
                            accountGeneration: accountGeneration,
                            scanGeneration: scanGeneration
                        )
                        return
                    }
                }
            }
            guard let response else { return }
            let persistedResponse = recoveredResponseForPersistence(response)
            locallyRecoveredResponse = persistedResponse
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ),
                  !cancelledTurns.contains(key),
                  !(await isChatStreaming(chatId))
            else {
                return
            }
            let storedChat = try? await storage.fileStorage.loadChat(
                chatId: chatId,
                userId: userId
            )
            let titleMessages = storedChat.flatMap {
                recoveredTitleMessages(
                    titleState: $0.titleState,
                    messages: $0.messages,
                    response: persistedResponse,
                    turnId: envelope.turnId
                )
            }
            if let titleMessages {
                generatedTitle = await SummarizerService.shared.generateChatTitle(
                    from: titleMessages
                )
            }
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ),
                  !cancelledTurns.contains(key),
                  !(await isChatStreaming(chatId))
            else {
                return
            }
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                storage: storage,
                mutation: .complete(
                    envelope: envelope,
                    response: persistedResponse,
                    title: generatedTitle,
                    titleState: generatedTitle == nil ? nil : .generated
                )
            )
            if accountIsCurrent(
                accountGeneration: accountGeneration,
                userId: userId
            ) {
                await MainActor.run {
                    ChatRecoveryDraftStore.shared.clear(
                        chatId: chatId,
                        turnId: turnId
                    )
                }
                postRecoveryUpdate(
                    chatId: chatId,
                    userId: userId,
                    storage: storage
                )
            }
            await deleteSessionAfterMutation(payload.sessionId)
        } catch ChatRecoverySyncError.envelopeMissing {
            guard await recoveryScanCanMutate(
                chatId: chatId,
                turnId: envelope.turnId,
                storage: storage,
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            if storage == .cloud {
                let reconciled = try? await ChatRecoverySync.shared.reconcileResolvedTurnFromRemote(
                    chatId: chatId,
                    turnId: envelope.turnId,
                    userId: userId,
                    isCurrent: {
                        await self.recoveryScanCanMutate(
                            chatId: chatId,
                            turnId: turnId,
                            storage: storage,
                            accountGeneration: accountGeneration,
                            scanGeneration: scanGeneration,
                            userId: userId
                        )
                    }
                )
                guard await recoveryScanCanMutate(
                    chatId: chatId,
                    turnId: envelope.turnId,
                    storage: storage,
                    accountGeneration: accountGeneration,
                    scanGeneration: scanGeneration,
                    userId: userId
                ) else { return }
                if reconciled == true {
                    try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
                    postRecoveryUpdate(
                        chatId: chatId,
                        userId: userId,
                        storage: storage
                    )
                    return
                }
                guard let response = locallyRecoveredResponse else { return }
                let containsEnvelope = try? await storage.fileStorage.containsPendingRecovery(
                    chatId: chatId,
                    userId: userId,
                    envelope: envelope
                )
                guard containsEnvelope == true,
                      await recoveryScanCanMutate(
                          chatId: chatId,
                          turnId: envelope.turnId,
                          storage: storage,
                          accountGeneration: accountGeneration,
                          scanGeneration: scanGeneration,
                          userId: userId
                      ) else { return }
                do {
                    _ = try await ChatRecoverySync.shared.mutateLocally(
                        chatId: chatId,
                        userId: userId,
                        storage: storage,
                        mutation: .complete(
                            envelope: envelope,
                            response: response,
                            title: generatedTitle,
                            titleState: generatedTitle == nil ? nil : .generated
                        )
                    )
                    guard recoveryScanCompletionIsCurrent(
                        chatId: chatId,
                        turnId: envelope.turnId,
                        storage: storage,
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ) else { return }
                    try await CloudSyncService.shared.backupRecoveryChatAndWait(
                        chatId,
                        allowWhileStreaming: true
                    )
                    await deleteSessionAfterMutation(payload.sessionId)
                    guard recoveryScanCompletionIsCurrent(
                        chatId: chatId,
                        turnId: envelope.turnId,
                        storage: storage,
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId
                    ) else { return }
                    postRecoveryUpdate(
                        chatId: chatId,
                        userId: userId,
                        storage: storage
                    )
                } catch {
                    return
                }
                return
            }
            try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
            postRecoveryUpdate(
                chatId: chatId,
                userId: userId,
                storage: storage
            )
        } catch ChatRecoveryClientError.state(let state)
            where state == .failed || state == .missing {
            guard scanIsCurrent(
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId
            ) else {
                return
            }
            await removeTerminal(
                chatId: chatId,
                envelope: envelope,
                userId: userId,
                sessionId: payload.sessionId,
                storage: storage,
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration
            )
        } catch {
            return
        }
    }

    private func openEnvelope(
        _ envelope: PendingRecoveryEnvelope,
        chatId: String,
        userId: String,
        storage: ChatRecoveryStorage,
        now: Date = Date()
    ) async throws -> (
        payload: ChatRecoveryEnvelopePayload,
        cek: Data,
        usedHistoricalKey: Bool
    ) {
        if storage == .local {
            let deviceKey = try await DeviceEncryptionService.shared.getKeyBytesOrThrow()
            let payload = try ChatRecoveryCrypto.decrypt(
                cek: deviceKey,
                userId: userId,
                chatId: chatId,
                envelope: envelope,
                now: now
            )
            return (payload, deviceKey, false)
        }
        let primary = try EncryptionService.shared.getKeyBytesOrThrow()
        let primaryKeyId = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: primary)
        if primaryKeyId == envelope.keyId {
            let payload = try ChatRecoveryCrypto.decrypt(
                cek: primary,
                userId: userId,
                chatId: chatId,
                envelope: envelope,
                now: now
            )
            return (payload, primary, false)
        }
        for key in EncryptionService.shared.getActiveKeys().alternatives {
            guard let cek = try? EncryptionService.shared.getAlternativeKeyBytes(key),
                  let keyId = try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek),
                  keyId == envelope.keyId
            else {
                continue
            }
            let payload = try ChatRecoveryCrypto.decrypt(
                cek: cek,
                userId: userId,
                chatId: chatId,
                envelope: envelope,
                now: now
            )
            return (payload, cek, true)
        }
        throw ChatRecoveryCryptoError.invalidKey
    }

    private func waitForRecoveryRetry(attempt: Int) async throws {
        try await Task<Never, Never>.sleep(
            nanoseconds: chatRecoveryRetryDelayNanoseconds(attempt: attempt)
        )
    }

    private func reconstructMessage(
        stream: AsyncThrowingStream<ChatStreamResult, Error>,
        modelDisplayName: String?,
        chatId: String,
        turnId: String,
        sessionId: String,
        userId: String,
        accountGeneration: Int,
        scanGeneration: Int,
        storage: ChatRecoveryStorage,
        onProgress: @escaping @Sendable () async -> Void
    ) async throws -> Message {
        let modelDisplayNamesByName = await MainActor.run {
            AppConfig.shared.modelDisplayNamesByName
        }
        let processor = SynchronizedStreamingResponseProcessor(
            StreamingResponseProcessor(
                isWebSearchEnabled: true,
                hapticEnabled: false,
                modelDisplayName: modelDisplayName,
                modelDisplayNamesByName: modelDisplayNamesByName
            )
        )
        let snapshotPublisher = LazySnapshotPublisher(
            interval: Constants.Streaming.uiUpdateInterval,
            buildSnapshot: processor.snapshot
        )
        let snapshotPublicationFence = SnapshotPublicationFence()
        var eventState = RecoveredEventState()
        var lastProgressDraft: Message?
        do {
            for try await chunk in stream {
                let parsed = processor.parse(chunk)
                let outcome = processor.withProcessor { underlyingProcessor in
                    for event in parsed.events {
                        eventState.apply(event, processor: underlyingProcessor)
                    }
                    return underlyingProcessor.process(parsed)
                }
                if outcome.didMutateState || !parsed.events.isEmpty {
                    snapshotPublisher.markDirty()
                    let publication = snapshotPublisher.acceptUpdate(
                        at: Date(),
                        scheduleTrailing: false
                    )
                    if let materializedSnapshot = publication.materializedSnapshot,
                       snapshotPublicationFence.accept(materializedSnapshot.id) {
                        try ensureRecoveryIsCurrent(
                            chatId: chatId,
                            turnId: turnId,
                            userId: userId,
                            accountGeneration: accountGeneration,
                            scanGeneration: scanGeneration,
                            storage: storage
                        )
                        let draft = recoveredMessage(
                            snapshot: materializedSnapshot.snapshot,
                            eventState: eventState,
                            chatId: chatId,
                            turnId: turnId,
                            isStreaming: true
                        )
                        if recoveryDraftHasVisibleContent(draft) {
                            let published = try await publishRecoveryDraft(
                                draft,
                                chatId: chatId,
                                turnId: turnId,
                                sessionId: sessionId,
                                accountGeneration: accountGeneration,
                                scanGeneration: scanGeneration,
                                userId: userId,
                                storage: storage
                            )
                            if published && draft != lastProgressDraft {
                                lastProgressDraft = draft
                                await onProgress()
                            }
                        }
                    }
                }
            }
        } catch {
            snapshotPublisher.cancelTrailing()
            if let materializedSnapshot = snapshotPublisher.flushIfDirty() {
                let draft = recoveredMessage(
                    snapshot: materializedSnapshot.snapshot,
                    eventState: eventState,
                    chatId: chatId,
                    turnId: turnId,
                    isStreaming: true
                )
                if recoveryDraftHasVisibleContent(draft) {
                    let published = try? await publishRecoveryDraft(
                        draft,
                        chatId: chatId,
                        turnId: turnId,
                        sessionId: sessionId,
                        accountGeneration: accountGeneration,
                        scanGeneration: scanGeneration,
                        userId: userId,
                        storage: storage
                    )
                    if published == true && draft != lastProgressDraft {
                        await onProgress()
                    }
                }
            }
            throw error
        }
        snapshotPublisher.cancelTrailing()
        let finalSnapshot = try processor.finishAndSnapshot()
        try ensureRecoveryIsCurrent(
            chatId: chatId,
            turnId: turnId,
            userId: userId,
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            storage: storage
        )
        let message = recoveredMessage(
            snapshot: finalSnapshot,
            eventState: eventState,
            chatId: chatId,
            turnId: turnId,
            isStreaming: false
        )
        if recoveryDraftHasVisibleContent(message) {
            var finalDraft = message
            finalDraft.isStreaming = true
            let published = try await publishRecoveryDraft(
                finalDraft,
                chatId: chatId,
                turnId: turnId,
                sessionId: sessionId,
                accountGeneration: accountGeneration,
                scanGeneration: scanGeneration,
                userId: userId,
                storage: storage
            )
            if published && message != lastProgressDraft {
                await onProgress()
            }
        }
        return message
    }

    private func publishRecoveryDraft(
        _ draft: Message,
        chatId: String,
        turnId: String,
        sessionId: String,
        accountGeneration: Int,
        scanGeneration: Int,
        userId: String,
        storage: ChatRecoveryStorage
    ) async throws -> Bool {
        try ensureRecoveryIsCurrent(
            chatId: chatId,
            turnId: turnId,
            userId: userId,
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            storage: storage
        )
        let published = await MainActor.run { () -> Bool? in
            guard !StreamingTracker.shared.isStreaming(chatId) else {
                ChatRecoveryDraftStore.shared.clear(
                    chatId: chatId,
                    turnId: turnId
                )
                return nil
            }
            return ChatRecoveryDraftStore.shared.replaceDuringReplay(
                draft,
                chatId: chatId,
                turnId: turnId,
                sessionId: sessionId,
                generation: accountGeneration,
                scanGeneration: scanGeneration
            )
        }
        try ensureRecoveryIsCurrent(
            chatId: chatId,
            turnId: turnId,
            userId: userId,
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            storage: storage
        )
        guard let published else { throw CancellationError() }
        return published
    }

    private func recoveredMessage(
        snapshot: StreamingResponseProcessor.Snapshot,
        eventState: RecoveredEventState,
        chatId: String,
        turnId: String,
        isStreaming: Bool
    ) -> Message {
        var webSearchState = eventState.webSearchState
        if !snapshot.collectedSources.isEmpty {
            var state = webSearchState ?? WebSearchState(status: .searching)
            state.sources = snapshot.collectedSources
            if state.status == .searching {
                state.status = .completed
            }
            webSearchState = state
        }
        var message = Message(
            id: recoveryDraftMessageId(chatId: chatId, turnId: turnId),
            role: .assistant,
            turnId: turnId,
            content: snapshot.responseContent,
            modelDisplayName: snapshot.modelDisplayName,
            thoughts: snapshot.thoughts,
            isThinking: snapshot.isThinking,
            timestamp: .distantPast,
            generationTimeSeconds: snapshot.generationTimeSeconds,
            contentChunks: snapshot.contentChunks,
            thinkingChunks: snapshot.thinkingChunks,
            webSearchState: webSearchState
        )
        message.isStreaming = isStreaming
        message.thinkingDuration = snapshot.generationTimeSeconds
        message.segments = snapshot.segments
        message.webSearches = snapshot.webSearches
        message.toolCalls = snapshot.toolCalls
        message.timeline = snapshot.timelineBlocks
        message.urlFetches = eventState.urlFetches
        message.annotations = snapshot.collectedAnnotations
        if let webSearchBeforeThinking = snapshot.webSearchBeforeThinking {
            message.webSearchBeforeThinking = webSearchBeforeThinking
        }
        return message
    }

    private func ensureRecoveryIsCurrent(
        chatId: String,
        turnId: String,
        userId: String,
        accountGeneration: Int,
        scanGeneration: Int,
        storage: ChatRecoveryStorage
    ) throws {
        let key = turnKey(chatId: chatId, turnId: turnId, storage: storage)
        guard scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ),
              !cancelledTurns.contains(key)
        else {
            throw CancellationError()
        }
    }

    private func scanIsCurrent(
        accountGeneration: Int,
        scanGeneration: Int,
        userId: String
    ) -> Bool {
        !Task.isCancelled
            && accountIsCurrent(
                accountGeneration: accountGeneration,
                userId: userId
            )
            && scanGeneration == self.scanGeneration
    }

    private func recoveryScanCanMutate(
        chatId: String,
        turnId: String,
        storage: ChatRecoveryStorage,
        accountGeneration: Int,
        scanGeneration: Int,
        userId: String
    ) async -> Bool {
        let key = turnKey(chatId: chatId, turnId: turnId, storage: storage)
        guard scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ),
              !cancelledTurns.contains(key),
              !(await isChatStreaming(chatId)) else {
            return false
        }
        return scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ) && !cancelledTurns.contains(key)
    }

    private func recoveryScanCompletionIsCurrent(
        chatId: String,
        turnId: String,
        storage: ChatRecoveryStorage,
        accountGeneration: Int,
        scanGeneration: Int,
        userId: String
    ) -> Bool {
        let key = turnKey(chatId: chatId, turnId: turnId, storage: storage)
        return scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ) && !cancelledTurns.contains(key)
    }

    private func accountIsCurrent(
        accountGeneration: Int,
        userId: String
    ) -> Bool {
        accountGeneration == self.accountGeneration
            && activeAccountId == userId
    }

    private func removeTerminal(
        chatId: String,
        envelope: PendingRecoveryEnvelope,
        userId: String,
        sessionId: String?,
        storage: ChatRecoveryStorage,
        accountGeneration: Int,
        scanGeneration: Int
    ) async {
        guard scanIsCurrent(
            accountGeneration: accountGeneration,
            scanGeneration: scanGeneration,
            userId: userId
        ),
              !(await isChatStreaming(chatId)),
              scanIsCurrent(
                  accountGeneration: accountGeneration,
                  scanGeneration: scanGeneration,
                  userId: userId
              )
        else {
            return
        }
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                storage: storage,
                mutation: .remove(envelope)
            )
            if accountIsCurrent(
                accountGeneration: accountGeneration,
                userId: userId
            ) {
                await MainActor.run {
                    ChatRecoveryDraftStore.shared.discard(
                        chatId: chatId,
                        turnId: envelope.turnId
                    )
                }
                postRecoveryUpdate(
                    chatId: chatId,
                    userId: userId,
                    storage: storage
                )
            }
            await deleteSessionAfterMutation(sessionId)
        } catch {
            if let sessionId,
               scanIsCurrent(
                   accountGeneration: accountGeneration,
                   scanGeneration: scanGeneration,
                   userId: userId
               ) {
                try? await ChatRecoveryClient.shared.delete(sessionId: sessionId)
            }
            return
        }
    }

    private func deleteSessionAfterMutation(_ sessionId: String?) async {
        guard let sessionId else { return }
        await Task {
            try? await ChatRecoveryClient.shared.delete(sessionId: sessionId)
        }.value
    }

    private func randomSessionId() throws -> String {
        var bytes = [UInt8](repeating: 0, count: Constants.ChatRecovery.sessionIdBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ChatRecoveryClientError.unavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func isChatStreaming(_ chatId: String) async -> Bool {
        await MainActor.run {
            StreamingTracker.shared.isStreaming(chatId)
        }
    }

    private func turnKey(
        chatId: String,
        turnId: String,
        storage: ChatRecoveryStorage
    ) -> String {
        "\(storage.rawValue)\u{0}\(chatId)\u{0}\(turnId)"
    }

    private func hasActiveRecovery(
        turnId: String,
        excluding key: String? = nil
    ) -> Bool {
        activeRecoveryTasks.contains {
            $0.key != key && $0.value.turnId == turnId
        }
    }

    private func postRecoveryUpdate(
        chatId: String,
        userId: String,
        storage: ChatRecoveryStorage
    ) {
        NotificationCenter.default.post(
            name: .chatRecoveryDidUpdate,
            object: nil,
            userInfo: [
                ChatRecoveryNotificationKey.chatId: chatId,
                ChatRecoveryNotificationKey.userId: userId,
                ChatRecoveryNotificationKey.storage: storage.rawValue,
            ]
        )
    }
}

private struct RecoveredEventState {
    var webSearchState: WebSearchState?
    var urlFetches: [URLFetchState] = []

    mutating func apply(
        _ event: TinfoilWebSearchCallEvent,
        processor: StreamingResponseProcessor
    ) {
        if event.action?.type == "open_page", let url = event.action?.url {
            let fetchId = event.itemId ?? url
            let status: URLFetchStatus
            switch event.status {
            case .inProgress, .searching:
                status = .fetching
            case .completed:
                status = .completed
            case .failed:
                status = .failed
            case .blocked:
                status = .blocked
            }
            if let index = urlFetches.firstIndex(where: { $0.id == fetchId }) {
                urlFetches[index].status = status
            } else {
                urlFetches.append(URLFetchState(id: fetchId, url: url, status: status))
                processor.appendURLFetchSegment(fetchId)
            }
            return
        }

        let sources = event.sources?.compactMap { source -> WebSearchSource? in
            guard let url = source.url, !url.isEmpty else { return nil }
            return WebSearchSource(title: source.title ?? url, url: url)
        }
        let existing = processor.findSearchInstance(matching: event.itemId)
        let id = existing?.id ?? event.itemId ?? processor.allocateSearchId()
        let status: WebSearchStatus
        switch event.status {
        case .inProgress, .searching:
            status = .searching
            processor.markWebSearchStarted()
        case .completed:
            status = .completed
        case .failed:
            status = .failed
        case .blocked:
            status = .blocked
        }
        let mergedSources = (sources?.isEmpty == false) ? sources : existing?.sources
        processor.upsertWebSearch(
            WebSearchInstance(
                id: id,
                query: event.action?.query ?? existing?.query,
                status: status,
                sources: mergedSources,
                reason: event.error?.code ?? existing?.reason
            )
        )
        webSearchState = WebSearchState(
            query: event.action?.query ?? existing?.query,
            status: status,
            sources: mergedSources ?? [],
            reason: event.error?.code
        )
    }
}
