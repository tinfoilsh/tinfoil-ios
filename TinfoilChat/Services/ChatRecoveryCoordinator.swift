import Combine
import Foundation
@preconcurrency import OpenAI
import Security

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
}

actor ChatRecoveryCoordinator {
    static let shared = ChatRecoveryCoordinator()

    private var accountGeneration = 0
    private var cancelledTurns: Set<String> = []
    private var activeAccountId: String?
    private var isScanning = false

    func reset(accountId: String?) async {
        accountGeneration += 1
        activeAccountId = accountId
        cancelledTurns.removeAll()
        isScanning = false
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

    func register(
        attempt: ChatRecoveryAttempt,
        token: ChatRecoveryTokenPayload
    ) async throws -> PendingRecoveryEnvelope {
        let key = turnKey(
            chatId: attempt.chatId,
            turnId: attempt.turnId,
            storage: attempt.storage
        )
        if cancelledTurns.contains(key)
            || attempt.generation != accountGeneration
            || activeAccountId != attempt.userId {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            throw CancellationError()
        }
        let cek: Data
        switch attempt.storage {
        case .cloud:
            cek = try EncryptionService.shared.getKeyBytesOrThrow()
        case .local:
            cek = try await DeviceEncryptionService.shared.getKeyBytesOrThrow()
        }
        let envelope = try ChatRecoveryCrypto.encrypt(
            cek: cek,
            userId: attempt.userId,
            chatId: attempt.chatId,
            turnId: attempt.turnId,
            sessionId: attempt.sessionId,
            recoveryToken: token
        )
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: attempt.chatId,
                userId: attempt.userId,
                storage: attempt.storage,
                mutation: .add(envelope)
            )
        } catch {
            if case ChatRecoverySyncError.pendingLimitReached = error {
                try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            } else if attempt.storage == .local,
                      case ChatRecoverySyncError.chatMissing = error {
                try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            }
            throw error
        }
        if cancelledTurns.contains(key)
            || attempt.generation != accountGeneration
            || activeAccountId != attempt.userId {
            await cancel(attempt: attempt)
            throw CancellationError()
        }
        return envelope
    }

    func complete(
        attempt: ChatRecoveryAttempt,
        envelope: PendingRecoveryEnvelope,
        response: Message,
        title: String? = nil,
        titleState: Chat.TitleState? = nil
    ) async throws {
        let key = turnKey(
            chatId: attempt.chatId,
            turnId: attempt.turnId,
            storage: attempt.storage
        )
        guard !cancelledTurns.contains(key),
              attempt.generation == accountGeneration,
              activeAccountId == attempt.userId
        else {
            await cancel(attempt: attempt)
            throw CancellationError()
        }
        do {
            try await ChatRecoverySync.shared.mutate(
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
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
        } catch ChatRecoverySyncError.envelopeMissing {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            if attempt.storage == .cloud {
                try await ChatRecoverySync.shared.refreshFromRemote(
                    chatId: attempt.chatId,
                    userId: attempt.userId
                )
            }
            postRecoveryUpdate(
                chatId: attempt.chatId,
                userId: attempt.userId,
                storage: attempt.storage
            )
        } catch {
            throw error
        }
    }

    func cancel(attempt: ChatRecoveryAttempt, response: Message? = nil) async {
        cancelledTurns.insert(turnKey(
            chatId: attempt.chatId,
            turnId: attempt.turnId,
            storage: attempt.storage
        ))
        await MainActor.run {
            ChatRecoveryPhaseTracker.shared.clear(turnId: attempt.turnId)
            ChatRecoveryDraftStore.shared.discard(
                chatId: attempt.chatId,
                turnId: attempt.turnId
            )
        }
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: attempt.chatId,
                userId: attempt.userId,
                storage: attempt.storage,
                mutation: .cancel(turnId: attempt.turnId, response: response)
            )
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
        } catch ChatRecoverySyncError.envelopeMissing {
            if attempt.storage == .cloud {
                try? await ChatRecoverySync.shared.refreshFromRemote(
                    chatId: attempt.chatId,
                    userId: attempt.userId
                )
            }
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            postRecoveryUpdate(
                chatId: attempt.chatId,
                userId: attempt.userId,
                storage: attempt.storage
            )
        } catch {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            return
        }
    }

    func deleteSession(attempt: ChatRecoveryAttempt) async {
        try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
    }

    func scan(userId: String, storages: [ChatRecoveryStorage]) async {
        if activeAccountId != userId {
            await reset(accountId: userId)
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let generation = accountGeneration
        var work: [(String, PendingRecoveryEnvelope, ChatRecoveryStorage)] = []
        for storage in storages {
            guard !Task.isCancelled else { return }
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
                        await self.recover(
                            chatId: item.0,
                            envelope: item.1,
                            userId: userId,
                            generation: generation,
                            storage: item.2
                        )
                    }
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { return }
                if let item = iterator.next() {
                    group.addTask {
                        await self.recover(
                            chatId: item.0,
                            envelope: item.1,
                            userId: userId,
                            generation: generation,
                            storage: item.2
                        )
                    }
                }
            }
        }
    }

    private func recover(
        chatId: String,
        envelope originalEnvelope: PendingRecoveryEnvelope,
        userId: String,
        generation: Int,
        storage: ChatRecoveryStorage
    ) async {
        guard !Task.isCancelled,
              generation == accountGeneration,
              activeAccountId == userId,
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
                envelope = rewrapped
                postRecoveryUpdate(
                    chatId: chatId,
                    userId: userId,
                    storage: storage
                )
            }
        } catch ChatRecoveryCryptoError.expired {
            await removeTerminal(
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                sessionId: nil,
                storage: storage
            )
            return
        } catch ChatRecoveryCryptoError.invalidEnvelope,
                ChatRecoveryCryptoError.decryptionFailed {
            await removeTerminal(
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                sessionId: nil,
                storage: storage
            )
            return
        } catch {
            return
        }

        guard !Task.isCancelled,
              generation == accountGeneration,
              activeAccountId == userId
        else {
            return
        }
        do {
            let state = try await ChatRecoveryClient.shared.state(sessionId: payload.sessionId)
            let turnId = envelope.turnId
            switch state {
            case .processing:
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.setPhase(.generating, turnId: turnId)
                }
            case .failed, .missing:
                await removeTerminal(
                    chatId: chatId,
                    turnId: envelope.turnId,
                    userId: userId,
                    sessionId: payload.sessionId,
                    storage: storage
                )
                return
            case .complete:
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.setPhase(.restoring, turnId: turnId)
                }
            }
            guard let token = payload.recoveryToken.fields else { return }
            let stream = try await ChatRecoveryClient.shared.fetch(
                sessionId: payload.sessionId,
                token: token
            )
            guard !Task.isCancelled else { return }
            let response = try await reconstructMessage(
                stream: stream,
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                generation: generation,
                storage: storage
            )
            let key = turnKey(
                chatId: chatId,
                turnId: envelope.turnId,
                storage: storage
            )
            guard generation == accountGeneration,
                  activeAccountId == userId,
                  !cancelledTurns.contains(key)
            else {
                try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
                return
            }
            guard !(await isChatStreaming(chatId)) else { return }
            guard !Task.isCancelled else { return }
            let finalState = try await ChatRecoveryClient.shared.state(
                sessionId: payload.sessionId
            )
            switch finalState {
            case .processing:
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.setPhase(.generating, turnId: turnId)
                }
                return
            case .failed, .missing:
                await removeTerminal(
                    chatId: chatId,
                    turnId: envelope.turnId,
                    userId: userId,
                    sessionId: payload.sessionId,
                    storage: storage
                )
                return
            case .complete:
                await MainActor.run {
                    ChatRecoveryPhaseTracker.shared.setPhase(.restoring, turnId: turnId)
                }
            }
            guard generation == accountGeneration,
                  activeAccountId == userId,
                  !cancelledTurns.contains(key),
                  !(await isChatStreaming(chatId)),
                  !Task.isCancelled
            else {
                return
            }
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                storage: storage,
                mutation: .complete(
                    envelope: envelope,
                    response: response,
                    title: nil,
                    titleState: nil
                )
            )
            try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
            await MainActor.run {
                ChatRecoveryPhaseTracker.shared.clear(turnId: turnId)
            }
            postRecoveryUpdate(
                chatId: chatId,
                userId: userId,
                storage: storage
            )
        } catch ChatRecoverySyncError.envelopeMissing {
            await MainActor.run {
                ChatRecoveryPhaseTracker.shared.clear(turnId: envelope.turnId)
            }
            if storage == .cloud {
                try? await ChatRecoverySync.shared.refreshFromRemote(
                    chatId: chatId,
                    userId: userId
                )
            }
            try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
            postRecoveryUpdate(
                chatId: chatId,
                userId: userId,
                storage: storage
            )
        } catch ChatRecoveryClientError.state(let state)
            where state == .failed || state == .missing {
            await removeTerminal(
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                sessionId: payload.sessionId,
                storage: storage
            )
        } catch {
            return
        }
    }

    private func openEnvelope(
        _ envelope: PendingRecoveryEnvelope,
        chatId: String,
        userId: String,
        storage: ChatRecoveryStorage
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
                envelope: envelope
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
                envelope: envelope
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
                envelope: envelope
            )
            return (payload, cek, true)
        }
        throw ChatRecoveryCryptoError.invalidKey
    }

    private func reconstructMessage(
        stream: AsyncThrowingStream<ChatStreamResult, Error>,
        chatId: String,
        turnId: String,
        userId: String,
        generation: Int,
        storage: ChatRecoveryStorage
    ) async throws -> Message {
        let processor = StreamingResponseProcessor(
            isWebSearchEnabled: true,
            hapticEnabled: false
        )
        var eventState = RecoveredEventState()
        for try await chunk in stream {
            let parsed = processor.parse(chunk)
            for event in parsed.events {
                eventState.apply(event, processor: processor)
            }
            let outcome = processor.process(parsed)
            if outcome.didMutateState || !parsed.events.isEmpty {
                try ensureRecoveryIsCurrent(
                    chatId: chatId,
                    turnId: turnId,
                    userId: userId,
                    generation: generation,
                    storage: storage
                )
                let draft = recoveredMessage(
                    snapshot: processor.snapshot(),
                    eventState: eventState,
                    chatId: chatId,
                    turnId: turnId,
                    isStreaming: true
                )
                if recoveredMessageIsMeaningful(draft) {
                    try await publishRecoveryDraft(
                        draft,
                        chatId: chatId,
                        turnId: turnId,
                        generation: generation
                    )
                }
            }
        }
        processor.finishStream()
        try ensureRecoveryIsCurrent(
            chatId: chatId,
            turnId: turnId,
            userId: userId,
            generation: generation,
            storage: storage
        )
        let message = recoveredMessage(
            snapshot: processor.snapshot(),
            eventState: eventState,
            chatId: chatId,
            turnId: turnId,
            isStreaming: false
        )
        if recoveredMessageIsMeaningful(message) {
            var finalDraft = message
            finalDraft.isStreaming = true
            try await publishRecoveryDraft(
                finalDraft,
                chatId: chatId,
                turnId: turnId,
                generation: generation
            )
        }
        return message
    }

    private func publishRecoveryDraft(
        _ draft: Message,
        chatId: String,
        turnId: String,
        generation: Int
    ) async throws {
        let published = await MainActor.run {
            guard !StreamingTracker.shared.isStreaming(chatId) else {
                ChatRecoveryDraftStore.shared.clear(
                    chatId: chatId,
                    turnId: turnId
                )
                return false
            }
            ChatRecoveryDraftStore.shared.replace(
                draft,
                chatId: chatId,
                turnId: turnId,
                generation: generation
            )
            return true
        }
        guard published else { throw CancellationError() }
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
            thoughts: snapshot.thoughts,
            isThinking: snapshot.isThinking,
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
        message.webSearchBeforeThinking = snapshot.webSearchBeforeThinking
        return message
    }

    private func recoveredMessageIsMeaningful(_ message: Message) -> Bool {
        !message.content.isEmpty
            || message.thoughts?.isEmpty == false
            || message.isThinking
            || message.segments?.isEmpty == false
            || message.webSearches?.isEmpty == false
            || message.webSearchState != nil
            || !message.urlFetches.isEmpty
            || !message.toolCalls.isEmpty
            || message.annotations?.isEmpty == false
            || message.timeline?.isEmpty == false
    }

    private func ensureRecoveryIsCurrent(
        chatId: String,
        turnId: String,
        userId: String,
        generation: Int,
        storage: ChatRecoveryStorage
    ) throws {
        let key = turnKey(chatId: chatId, turnId: turnId, storage: storage)
        guard !Task.isCancelled,
              generation == accountGeneration,
              activeAccountId == userId,
              !cancelledTurns.contains(key)
        else {
            throw CancellationError()
        }
    }

    private func removeTerminal(
        chatId: String,
        turnId: String,
        userId: String,
        sessionId: String?,
        storage: ChatRecoveryStorage
    ) async {
        await MainActor.run {
            ChatRecoveryPhaseTracker.shared.clear(turnId: turnId)
            ChatRecoveryDraftStore.shared.discard(
                chatId: chatId,
                turnId: turnId
            )
        }
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                storage: storage,
                mutation: .remove(turnId: turnId)
            )
            if let sessionId {
                try? await ChatRecoveryClient.shared.delete(sessionId: sessionId)
            }
            postRecoveryUpdate(
                chatId: chatId,
                userId: userId,
                storage: storage
            )
        } catch {
            if let sessionId {
                try? await ChatRecoveryClient.shared.delete(sessionId: sessionId)
            }
            return
        }
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
