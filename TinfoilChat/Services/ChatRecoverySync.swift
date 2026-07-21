import ClerkKit
import Foundation

enum ChatRecoverySyncError: Error {
    case chatMissing
    case envelopeMissing
    case pendingLimitReached
    case conflict
}

actor ChatRecoverySync {
    static let shared = ChatRecoverySync()

    enum Mutation {
        case add(PendingRecoveryEnvelope)
        case remove(turnId: String)
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
        mutation: Mutation
    ) async throws {
        var lastError: Error = ChatRecoverySyncError.conflict
        for _ in 0..<Constants.ChatRecovery.maxMutationAttempts {
            do {
                guard await Clerk.shared.user?.id == userId else {
                    throw ChatRecoverySyncError.chatMissing
                }
                guard let remote = try await CloudStorageService.shared.downloadChat(chatId) else {
                    throw ChatRecoverySyncError.chatMissing
                }
                let local = try? await EncryptedFileStorage.cloud.loadChat(
                    chatId: chatId,
                    userId: userId
                )
                guard let remoteChat = await MainActor.run(body: { remote.toChat() }) else {
                    throw ChatRecoverySyncError.chatMissing
                }
                var candidate = preferredBase(local: local, remote: remoteChat)
                try apply(mutation, to: &candidate, authoritativeRemote: remoteChat)
                candidate.syncVersion = remote.syncVersion
                stampEdit(&candidate, observedRemote: remoteChat)
                candidate.locallyModified = true

                guard await Clerk.shared.user?.id == userId else {
                    throw ChatRecoverySyncError.chatMissing
                }
                let result = try await CloudStorageService.shared.uploadChat(
                    StoredChat(from: candidate, syncVersion: remote.syncVersion),
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                applyAttachmentRewrites(result.rewrites, to: &candidate)
                candidate.syncVersion = result.syncVersion ?? remote.syncVersion + 1
                candidate.syncedAt = Date()
                candidate.locallyModified = false
                candidate.clockVersion = candidate.syncVersion
                guard await Clerk.shared.user?.id == userId else {
                    throw ChatRecoverySyncError.chatMissing
                }
                await applyLocally(
                    candidate,
                    mutation: mutation,
                    userId: userId,
                    expectedBaselineUpdatedAt: local?.updatedAt
                )
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
        case .remove(let turnId):
            pending.removeAll { $0.turnId == turnId }
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
            guard authoritativeRemote.pendingRecoveries?.contains(old) == true
                    || authoritativeRemote.pendingRecoveries?.contains(new) == true,
                  let index = pending.firstIndex(of: old)
            else {
                throw ChatRecoverySyncError.envelopeMissing
            }
            pending[index] = new
        case .complete(let envelope, let response, let title, let titleState):
            let alreadyCompleted = authoritativeRemote.messages.contains {
                sameRecoveredResponse($0, response)
            }
            guard (authoritativeRemote.pendingRecoveries?.contains(envelope) == true
                    || alreadyCompleted),
                  (pending.contains(envelope) || alreadyCompleted)
            else {
                throw ChatRecoverySyncError.envelopeMissing
            }
            pending.removeAll { $0.turnId == envelope.turnId }
            if let index = chat.messages.firstIndex(where: {
                $0.role == .assistant && $0.turnId == envelope.turnId
            }) {
                chat.messages[index] = response
            } else {
                chat.messages.append(response)
            }
            if let title {
                chat.title = title
            }
            if let titleState {
                chat.titleState = titleState
            }
        }
        chat.pendingRecoveries = pending.isEmpty ? nil : pending
    }

    private func sameRecoveredResponse(_ lhs: Message, _ rhs: Message) -> Bool {
        lhs.role == .assistant
            && lhs.turnId == rhs.turnId
            && lhs.content == rhs.content
            && lhs.thoughts == rhs.thoughts
            && lhs.generationTimeSeconds == rhs.generationTimeSeconds
            && lhs.segments == rhs.segments
            && lhs.webSearches == rhs.webSearches
            && lhs.webSearchState == rhs.webSearchState
            && lhs.urlFetches == rhs.urlFetches
            && lhs.toolCalls == rhs.toolCalls
            && lhs.timeline == rhs.timeline
            && lhs.annotations == rhs.annotations
    }

    private func stampEdit(_ chat: inout Chat, observedRemote: Chat) {
        EditClockStore.observe(chat.clock)
        EditClockStore.observe(observedRemote.clock)
        let clock = EditClockStore.nextClock(
            observedMax: max(chat.clock ?? 0, observedRemote.clock ?? 0)
        )
        chat.clock = clock.v
        chat.writer = clock.w
        chat.clockVersion = chat.syncVersion + 1
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
                stampEdit(&local, observedRemote: uploaded)
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: envelope.expiresAt).map { $0 <= Date() } ?? true
    }

}
