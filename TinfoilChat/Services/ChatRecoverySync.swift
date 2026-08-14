import ClerkKit
import Foundation

enum ChatRecoverySyncError: Error {
    case chatMissing
    case envelopeMissing
    case pendingLimitReached
    case conflict
}

struct ChatRecoveryLocalMutationResult: Sendable {
    let clock: Int?
    let writer: String?
    let clockVersion: Int?
    let updatedAt: Date
    let locallyModified: Bool
}

func remoteRecoveryTurnIsResolved(
    messages: [Message],
    pendingRecoveries: [PendingRecoveryEnvelope]?,
    turnId: String
) -> Bool {
    guard pendingRecoveries?.contains(where: { $0.turnId == turnId }) != true else {
        return false
    }
    return messages.contains {
        $0.role == .assistant
            && $0.turnId == turnId
            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

func resolvedRemoteMayReplaceLocal(
    localModified: Bool,
    localClock: EditClock?,
    remoteClock: EditClock?,
    localUpdatedAt: Date,
    remoteUpdatedAt: Date
) -> Bool {
    guard localModified else { return true }
    guard let localClock, let remoteClock else { return false }
    return SyncConflictResolver.remoteWins(
        localClock: localClock,
        remoteClock: remoteClock,
        localUpdatedAt: localUpdatedAt,
        remoteUpdatedAt: remoteUpdatedAt
    )
}

func mutateValidCloudRecoveryChat(
    _ chat: Chat,
    mutation: (inout Chat) throws -> Void
) throws -> Chat {
    guard !chat.decryptionFailed, !chat.dataCorrupted else {
        throw ChatRecoverySyncError.chatMissing
    }
    var candidate = chat
    try mutation(&candidate)
    return candidate
}

enum ChatRecoveryStorage: String, Sendable {
    case cloud
    case local

    var fileStorage: EncryptedFileStorage {
        switch self {
        case .cloud:
            return .cloud
        case .local:
            return .local
        }
    }
}

actor ChatRecoverySync {
    static let shared = ChatRecoverySync()
    private let expiryFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum Mutation {
        case add(PendingRecoveryEnvelope)
        case remove(PendingRecoveryEnvelope)
        case cancel(turnId: String, response: Message?)
        case replace(old: PendingRecoveryEnvelope, new: PendingRecoveryEnvelope)
        case complete(
            envelope: PendingRecoveryEnvelope,
            response: Message,
            title: String?,
            titleState: Chat.TitleState?
        )
    }

    func mutate(
        chatId: String,
        userId: String,
        storage: ChatRecoveryStorage,
        mutation: Mutation
    ) async throws {
        try Task.checkCancellation()
        if storage == .local {
            _ = try await mutateLocal(
                chatId: chatId,
                userId: userId,
                mutation: mutation
            )
            return
        }

        var lastError: Error = ChatRecoverySyncError.conflict
        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            do {
                try Task.checkCancellation()
                guard await Clerk.shared.user?.id == userId else {
                    throw ChatRecoverySyncError.chatMissing
                }
                guard let remote = try await CloudStorageService.shared.downloadChat(chatId) else {
                    throw ChatRecoverySyncError.chatMissing
                }
                try Task.checkCancellation()
                let loadedLocal = try? await EncryptedFileStorage.cloud.loadChat(
                    chatId: chatId,
                    userId: userId
                )
                try Task.checkCancellation()
                guard let remoteChat = await MainActor.run(body: { remote.toChat() }) else {
                    throw ChatRecoverySyncError.chatMissing
                }
                try Task.checkCancellation()
                guard !remoteChat.decryptionFailed, !remoteChat.dataCorrupted else {
                    throw ChatRecoverySyncError.chatMissing
                }
                let local = loadedLocal.flatMap {
                    $0.decryptionFailed || $0.dataCorrupted ? nil : $0
                }
                var candidate = preferredBase(local: local, remote: remoteChat)
                try apply(mutation, to: &candidate, authoritativeRemote: remoteChat)
                candidate.syncVersion = remote.syncVersion
                try stampEdit(&candidate, observedRemote: remoteChat)
                candidate.locallyModified = true

                guard await Clerk.shared.user?.id == userId else {
                    throw ChatRecoverySyncError.chatMissing
                }
                try Task.checkCancellation()
                let isRemoteDeleted = try await EncryptedFileStorage.cloud.hasRemoteDeleteTombstone(
                    chatId: chatId,
                    userId: userId
                )
                guard !isRemoteDeleted else { throw ChatRecoverySyncError.chatMissing }
                _ = try await CloudUploadGate.allowsWrite(required: true)
                try Task.checkCancellation()
                guard await Clerk.shared.user?.id == userId else {
                    throw ChatRecoverySyncError.chatMissing
                }
                let isDeletedBeforeUpload = try await EncryptedFileStorage.cloud
                    .hasRemoteDeleteTombstone(chatId: chatId, userId: userId)
                guard !isDeletedBeforeUpload else { throw ChatRecoverySyncError.chatMissing }
                try Task.checkCancellation()
                let result = try await CloudStorageService.shared.uploadChat(
                    StoredChat(from: candidate, syncVersion: remote.syncVersion),
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                applyAttachmentRewrites(result.rewrites, to: &candidate)
                guard let syncVersion = result.syncVersion
                    ?? ChatEditClockPolicy.nextSyncVersion(after: remote.syncVersion) else {
                    throw ChatRecoverySyncError.conflict
                }
                candidate.syncVersion = syncVersion
                candidate.syncedAt = Date()
                candidate.locallyModified = false
                candidate.clockVersion = candidate.syncVersion
                await Task {
                    await self.applyLocally(
                        candidate,
                        mutation: mutation,
                        userId: userId,
                        expectedBaselineUpdatedAt: local?.updatedAt
                    )
                }.value
                return
            } catch let error as SyncEnclaveError
                where EnclaveErrorRecovery.isVersionConflict(error) {
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    func mutateLocally(
        chatId: String,
        userId: String,
        storage: ChatRecoveryStorage,
        mutation: Mutation
    ) async throws -> ChatRecoveryLocalMutationResult {
        if storage == .local {
            return try await mutateLocal(
                chatId: chatId,
                userId: userId,
                mutation: mutation
            )
        }

        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            try Task.checkCancellation()
            guard await Clerk.shared.user?.id == userId,
                  let local = try await EncryptedFileStorage.cloud.loadChat(
                      chatId: chatId,
                      userId: userId
                  ) else {
                throw ChatRecoverySyncError.chatMissing
            }
            var candidate = try mutateValidCloudRecoveryChat(local) {
                try apply(mutation, to: &$0, authoritativeRemote: local)
            }
            try stampEdit(&candidate, observedRemote: local)
            candidate.locallyModified = true
            guard await Clerk.shared.user?.id == userId else {
                throw ChatRecoverySyncError.chatMissing
            }
            if try await EncryptedFileStorage.cloud.applyRemoteChatIfFresh(
                candidate,
                userId: userId,
                expectedLocalUpdatedAt: local.updatedAt,
                allowLocallyModified: true
            ) {
                return localResult(candidate)
            }
        }
        throw ChatRecoverySyncError.conflict
    }

    private func localResult(_ chat: Chat) -> ChatRecoveryLocalMutationResult {
        ChatRecoveryLocalMutationResult(
            clock: chat.clock,
            writer: chat.writer,
            clockVersion: chat.clockVersion,
            updatedAt: chat.updatedAt,
            locallyModified: chat.locallyModified
        )
    }

    private func mutateLocal(
        chatId: String,
        userId: String,
        mutation: Mutation
    ) async throws -> ChatRecoveryLocalMutationResult {
        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            try Task.checkCancellation()
            guard await Clerk.shared.user?.id == userId,
                  let local = try await EncryptedFileStorage.local.loadChat(
                      chatId: chatId,
                      userId: userId
                  )
            else {
                throw ChatRecoverySyncError.chatMissing
            }
            try Task.checkCancellation()
            var candidate = local
            try apply(mutation, to: &candidate, authoritativeRemote: local)
            candidate.updatedAt = Date()
            candidate.locallyModified = true
            guard await Clerk.shared.user?.id == userId else {
                throw ChatRecoverySyncError.chatMissing
            }
            try Task.checkCancellation()
            if try await EncryptedFileStorage.local.applyRemoteChatIfFresh(
                candidate,
                userId: userId,
                expectedLocalUpdatedAt: local.updatedAt,
                allowLocallyModified: true
            ) {
                return localResult(candidate)
            }
        }
        throw ChatRecoverySyncError.conflict
    }

    func refreshFromRemote(chatId: String, userId: String) async throws {
        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            guard await Clerk.shared.user?.id == userId,
                  let remote = try await CloudStorageService.shared.downloadChat(chatId),
                  var chat = await MainActor.run(body: { remote.toChat() }),
                  !chat.decryptionFailed,
                  !chat.dataCorrupted
            else {
                throw ChatRecoverySyncError.chatMissing
            }
            let local = try? await EncryptedFileStorage.cloud.loadChat(
                chatId: chatId,
                userId: userId
            )
            guard local?.locallyModified != true else {
                throw ChatRecoverySyncError.conflict
            }
            guard await Clerk.shared.user?.id == userId else {
                throw ChatRecoverySyncError.chatMissing
            }
            chat.syncedAt = Date()
            chat.locallyModified = false
            if try await EncryptedFileStorage.cloud.applyRemoteChatIfFresh(
                chat,
                userId: userId,
                expectedLocalUpdatedAt: local?.updatedAt
            ) {
                return
            }
        }
        throw ChatRecoverySyncError.conflict
    }

    func reconcileResolvedTurnFromRemote(
        chatId: String,
        turnId: String,
        userId: String,
        isCurrent: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        guard await Clerk.shared.user?.id == userId else { return false }
        guard let remote = try await CloudStorageService.shared.downloadChat(chatId),
              await isCurrent() else { return false }
        guard var remoteChat = await MainActor.run(body: { remote.toChat() }),
              !remoteChat.decryptionFailed,
              !remoteChat.dataCorrupted,
              await isCurrent(),
              remoteRecoveryTurnIsResolved(
                  messages: remoteChat.messages,
                  pendingRecoveries: remoteChat.pendingRecoveries,
                  turnId: turnId
              ) else {
            return false
        }
        let local = try await EncryptedFileStorage.cloud.loadChat(
            chatId: chatId,
            userId: userId
        )
        guard await isCurrent() else { return false }
        if let local,
           !resolvedRemoteMayReplaceLocal(
               localModified: local.locallyModified,
               localClock: trustedClock(local),
               remoteClock: trustedClock(remoteChat),
               localUpdatedAt: local.updatedAt,
               remoteUpdatedAt: remoteChat.updatedAt
           ) {
            return false
        }
        guard await Clerk.shared.user?.id == userId,
              await isCurrent() else { return false }
        remoteChat.syncedAt = Date()
        remoteChat.locallyModified = false
        return try await EncryptedFileStorage.cloud.applyRemoteChatIfFresh(
            remoteChat,
            userId: userId,
            expectedLocalUpdatedAt: local?.updatedAt,
            allowLocallyModified: true
        )
    }

    private func preferredBase(local: Chat?, remote: Chat) -> Chat {
        guard let local else { return remote }
        let localClock = trustedClock(local)
        let remoteClock = trustedClock(remote)
        let remoteWins = SyncConflictResolver.remoteWins(
            localClock: localClock,
            remoteClock: remoteClock,
            localUpdatedAt: local.updatedAt,
            remoteUpdatedAt: remote.updatedAt
        )
        return remoteWins ? remote : local
    }

    private func trustedClock(_ chat: Chat) -> EditClock? {
        guard let clock = chat.clock,
              let writer = chat.writer,
              chat.clockVersion == chat.syncVersion
        else {
            return nil
        }
        return EditClock(v: clock, w: writer)
    }

    private func applyAttachmentRewrites(
        _ rewrites: [CloudStorageService.AttachmentRewrite],
        to chat: inout Chat
    ) {
        let byClientId = Dictionary(
            rewrites.map { ($0.clientId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for messageIndex in chat.messages.indices {
            for attachmentIndex in chat.messages[messageIndex].attachments.indices {
                let clientId = chat.messages[messageIndex].attachments[attachmentIndex].id
                guard let rewrite = byClientId[clientId] else { continue }
                chat.messages[messageIndex].attachments[attachmentIndex].id = rewrite.serverId
                chat.messages[messageIndex].attachments[attachmentIndex].encryptionKey =
                    rewrite.encryptionKey
                chat.messages[messageIndex].attachments[attachmentIndex].base64 = nil
            }
        }
    }

    private func apply(
        _ mutation: Mutation,
        to chat: inout Chat,
        authoritativeRemote: Chat
    ) throws {
        var pending = chat.pendingRecoveries ?? []
        switch mutation {
        case .add(let envelope):
            pending.removeAll { $0.turnId == envelope.turnId }
            pending.removeAll { envelopeIsExpired($0) }
            guard pending.count < Constants.ChatRecovery.maxPendingPerChat else {
                throw ChatRecoverySyncError.pendingLimitReached
            }
            pending.append(envelope)
        case .remove(let envelope):
            guard authoritativeRemote.pendingRecoveries?.contains(envelope) == true,
                  let index = pending.firstIndex(of: envelope)
            else {
                throw ChatRecoverySyncError.envelopeMissing
            }
            pending.remove(at: index)
        case .cancel(let turnId, let response):
            guard authoritativeRemote.pendingRecoveries?.contains(where: {
                $0.turnId == turnId
            }) == true else {
                throw ChatRecoverySyncError.envelopeMissing
            }
            pending.removeAll { $0.turnId == turnId }
            if let response,
               let index = chat.messages.firstIndex(where: {
                   $0.role == .assistant && $0.turnId == turnId
               }) {
                chat.messages[index] = response
            }
        case .replace(let old, let new):
            if pending.contains(new) {
                break
            }
            guard authoritativeRemote.pendingRecoveries?.contains(old) == true
                    || authoritativeRemote.pendingRecoveries?.contains(new) == true,
                  let index = pending.firstIndex(of: old)
            else {
                throw ChatRecoverySyncError.envelopeMissing
            }
            pending[index] = new
        case .complete(let envelope, let response, let title, let titleState):
            let alreadyCompleted = authoritativeRemote.messages.contains {
                recoveryResponsePayloadMatches($0, response)
            }
            guard (authoritativeRemote.pendingRecoveries?.contains(envelope) == true
                    || alreadyCompleted),
                  (pending.contains(envelope) || alreadyCompleted)
            else {
                throw ChatRecoverySyncError.envelopeMissing
            }
            pending.removeAll { $0.turnId == envelope.turnId }
            chat.messages = mergingRecoveredResponse(
                response,
                into: chat.messages,
                turnId: envelope.turnId
            )
            let canApplyGeneratedTitle = titleState != .generated
                || (
                    authoritativeRemote.titleState == .placeholder
                        && chat.titleState == .placeholder
                )
            if canApplyGeneratedTitle {
                if let title {
                    chat.title = title
                }
                if let titleState {
                    chat.titleState = titleState
                }
            }
        }
        chat.pendingRecoveries = pending.isEmpty ? nil : pending
    }

    private func stampEdit(_ chat: inout Chat, observedRemote: Chat) throws {
        EditClockStore.observe(chat.clock)
        EditClockStore.observe(observedRemote.clock)
        let clock = try EditClockStore.nextClock(
            observedMax: max(chat.clock ?? 0, observedRemote.clock ?? 0)
        )
        chat.clock = clock.v
        chat.writer = clock.w
        guard let clockVersion = ChatEditClockPolicy.nextSyncVersion(after: chat.syncVersion) else {
            throw ChatRecoverySyncError.conflict
        }
        chat.clockVersion = clockVersion
        chat.updatedAt = Date()
    }

    private func applyLocally(
        _ uploaded: Chat,
        mutation: Mutation,
        userId: String,
        expectedBaselineUpdatedAt: Date?
    ) async {
        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            let loaded = try? await EncryptedFileStorage.cloud.loadChat(
                chatId: uploaded.id,
                userId: userId
            )
            guard loaded?.decryptionFailed != true,
                  loaded?.dataCorrupted != true else {
                return
            }
            let expectedUpdatedAt = loaded?.updatedAt
            var candidate: Chat
            if loaded?.updatedAt == expectedBaselineUpdatedAt {
                candidate = uploaded
            } else if var local = loaded {
                do {
                    try apply(mutation, to: &local, authoritativeRemote: uploaded)
                } catch {
                    return
                }
                local.syncVersion = uploaded.syncVersion
                do {
                    try stampEdit(&local, observedRemote: uploaded)
                } catch {
                    return
                }
                local.locallyModified = true
                candidate = local
            } else {
                return
            }
            let applied = (try? await EncryptedFileStorage.cloud.applyRemoteChatIfFresh(
                candidate,
                userId: userId,
                expectedLocalUpdatedAt: expectedUpdatedAt,
                allowLocallyModified: true
            )) ?? false
            if applied {
                if candidate.locallyModified {
                    await CloudSyncService.shared.backupChat(candidate.id)
                }
                return
            }
        }
    }

    private func envelopeIsExpired(_ envelope: PendingRecoveryEnvelope) -> Bool {
        expiryFormatter.date(from: envelope.expiresAt).map { $0 <= Date() } ?? true
    }

}
