import Foundation
@preconcurrency import OpenAI
import Security

struct ChatRecoveryAttempt: Sendable {
    let chatId: String
    let turnId: String
    let userId: String
    let sessionId: String
    let generation: Int
}

extension Notification.Name {
    static let chatRecoveryDidUpdate = Notification.Name("chatRecoveryDidUpdate")
}

actor ChatRecoveryCoordinator {
    static let shared = ChatRecoveryCoordinator()

    private var accountGeneration = 0
    private var cancelledTurns: Set<String> = []
    private var activeAccountId: String?
    private var isScanning = false

    func reset(accountId: String?) {
        accountGeneration += 1
        activeAccountId = accountId
        cancelledTurns.removeAll()
        isScanning = false
    }

    func begin(
        chatId: String,
        turnId: String,
        userId: String
    ) throws -> ChatRecoveryAttempt {
        if activeAccountId != userId {
            reset(accountId: userId)
        }
        cancelledTurns.remove(turnKey(chatId: chatId, turnId: turnId))
        return ChatRecoveryAttempt(
            chatId: chatId,
            turnId: turnId,
            userId: userId,
            sessionId: try randomSessionId(),
            generation: accountGeneration
        )
    }

    func register(
        attempt: ChatRecoveryAttempt,
        token: ChatRecoveryTokenPayload
    ) async throws -> PendingRecoveryEnvelope {
        let key = turnKey(chatId: attempt.chatId, turnId: attempt.turnId)
        if cancelledTurns.contains(key)
            || attempt.generation != accountGeneration
            || activeAccountId != attempt.userId {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            throw CancellationError()
        }
        let cek = try EncryptionService.shared.getKeyBytesOrThrow()
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
                mutation: .add(envelope)
            )
        } catch {
            if case ChatRecoverySyncError.pendingLimitReached = error {
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
        let key = turnKey(chatId: attempt.chatId, turnId: attempt.turnId)
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
                mutation: .complete(
                    envelope: envelope,
                    response: response,
                    title: title,
                    titleState: titleState
                )
            )
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
        } catch ChatRecoverySyncError.envelopeMissing {
            try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
            try await ChatRecoverySync.shared.refreshFromRemote(
                chatId: attempt.chatId,
                userId: attempt.userId
            )
            postRecoveryUpdate(chatId: attempt.chatId)
        } catch {
            throw error
        }
    }

    func cancel(attempt: ChatRecoveryAttempt, response: Message? = nil) async {
        cancelledTurns.insert(turnKey(chatId: attempt.chatId, turnId: attempt.turnId))
        try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: attempt.chatId,
                userId: attempt.userId,
                mutation: .cancel(turnId: attempt.turnId, response: response)
            )
        } catch ChatRecoverySyncError.envelopeMissing {
            try? await ChatRecoverySync.shared.refreshFromRemote(
                chatId: attempt.chatId,
                userId: attempt.userId
            )
            postRecoveryUpdate(chatId: attempt.chatId)
        } catch {
            return
        }
    }

    func deleteSession(attempt: ChatRecoveryAttempt) async {
        try? await ChatRecoveryClient.shared.delete(sessionId: attempt.sessionId)
    }

    func scan(userId: String) async {
        if activeAccountId != userId {
            reset(accountId: userId)
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let generation = accountGeneration
        let entries = (try? await EncryptedFileStorage.cloud.loadIndex(userId: userId)) ?? []
        let storedChats = (try? await EncryptedFileStorage.cloud.loadChats(
            chatIds: entries.map(\.id),
            userId: userId
        )) ?? []
        let work = storedChats.flatMap { chat in
            (chat.pendingRecoveries ?? []).map { (chat.id, $0) }
        }
        guard !work.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            for _ in 0..<min(Constants.ChatRecovery.maxConcurrentScans, work.count) {
                if let item = iterator.next() {
                    group.addTask {
                        await self.recover(
                            chatId: item.0,
                            envelope: item.1,
                            userId: userId,
                            generation: generation
                        )
                    }
                }
            }
            while await group.next() != nil {
                if let item = iterator.next() {
                    group.addTask {
                        await self.recover(
                            chatId: item.0,
                            envelope: item.1,
                            userId: userId,
                            generation: generation
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
        generation: Int
    ) async {
        guard generation == accountGeneration, activeAccountId == userId else { return }
        var envelope = originalEnvelope
        let payload: ChatRecoveryEnvelopePayload
        do {
            if try ChatRecoveryCrypto.isExpired(envelope) {
                throw ChatRecoveryCryptoError.expired
            }
            let opened = try openEnvelope(
                envelope,
                chatId: chatId,
                userId: userId
            )
            payload = opened.payload
            if opened.usedHistoricalKey {
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
                    mutation: .replace(old: envelope, new: rewrapped)
                )
                envelope = rewrapped
                postRecoveryUpdate(chatId: chatId)
            }
        } catch ChatRecoveryCryptoError.expired {
            await removeTerminal(
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                sessionId: nil
            )
            return
        } catch ChatRecoveryCryptoError.invalidEnvelope,
                ChatRecoveryCryptoError.decryptionFailed {
            await removeTerminal(
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                sessionId: nil
            )
            return
        } catch {
            return
        }

        guard generation == accountGeneration, activeAccountId == userId else { return }
        do {
            let state = try await ChatRecoveryClient.shared.state(sessionId: payload.sessionId)
            switch state {
            case .processing:
                return
            case .failed, .missing:
                await removeTerminal(
                    chatId: chatId,
                    turnId: envelope.turnId,
                    userId: userId,
                    sessionId: payload.sessionId
                )
                return
            case .complete:
                break
            }
            guard let token = payload.recoveryToken.fields else { return }
            let stream = try await ChatRecoveryClient.shared.fetch(
                sessionId: payload.sessionId,
                token: token
            )
            let response = try await reconstructMessage(
                stream: stream,
                turnId: envelope.turnId
            )
            let key = turnKey(chatId: chatId, turnId: envelope.turnId)
            guard generation == accountGeneration,
                  activeAccountId == userId,
                  !cancelledTurns.contains(key)
            else {
                try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
                return
            }
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                mutation: .complete(
                    envelope: envelope,
                    response: response,
                    title: nil,
                    titleState: nil
                )
            )
            try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
            postRecoveryUpdate(chatId: chatId)
        } catch ChatRecoverySyncError.envelopeMissing {
            try? await ChatRecoveryClient.shared.delete(sessionId: payload.sessionId)
            try? await ChatRecoverySync.shared.refreshFromRemote(
                chatId: chatId,
                userId: userId
            )
            postRecoveryUpdate(chatId: chatId)
        } catch ChatRecoveryClientError.state(let state)
            where state == .failed || state == .missing {
            await removeTerminal(
                chatId: chatId,
                turnId: envelope.turnId,
                userId: userId,
                sessionId: payload.sessionId
            )
        } catch {
            return
        }
    }

    private func openEnvelope(
        _ envelope: PendingRecoveryEnvelope,
        chatId: String,
        userId: String
    ) throws -> (
        payload: ChatRecoveryEnvelopePayload,
        cek: Data,
        usedHistoricalKey: Bool
    ) {
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
        turnId: String
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
            _ = processor.process(parsed)
        }
        processor.finishStream()
        let snapshot = processor.snapshot()
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
            role: .assistant,
            turnId: turnId,
            content: snapshot.responseContent,
            thoughts: snapshot.thoughts,
            isThinking: false,
            generationTimeSeconds: snapshot.generationTimeSeconds,
            contentChunks: snapshot.contentChunks,
            thinkingChunks: snapshot.thinkingChunks,
            webSearchState: webSearchState
        )
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

    private func removeTerminal(
        chatId: String,
        turnId: String,
        userId: String,
        sessionId: String?
    ) async {
        if let sessionId {
            try? await ChatRecoveryClient.shared.delete(sessionId: sessionId)
        }
        do {
            try await ChatRecoverySync.shared.mutate(
                chatId: chatId,
                userId: userId,
                mutation: .remove(turnId: turnId)
            )
            postRecoveryUpdate(chatId: chatId)
        } catch {
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

    private func turnKey(chatId: String, turnId: String) -> String {
        "\(chatId)\u{0}\(turnId)"
    }

    private func postRecoveryUpdate(chatId: String) {
        NotificationCenter.default.post(
            name: .chatRecoveryDidUpdate,
            object: nil,
            userInfo: ["chatId": chatId]
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
