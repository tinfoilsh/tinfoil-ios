import Foundation
import Testing
@testable import TinfoilChat

struct ChatRecoverySchedulingTests {
    @Test func emptyThinkingDraftDoesNotReplaceRecoveryIndicator() {
        let emptyThinking = Message(
            role: .assistant,
            content: "",
            modelDisplayName: "GPT-OSS 120B",
            isThinking: true
        )
        let recoveredThought = Message(
            role: .assistant,
            content: "",
            thoughts: "Recovered reasoning",
            isThinking: true
        )

        #expect(!recoveryDraftHasVisibleContent(emptyThinking))
        #expect(recoveryDraftHasVisibleContent(recoveredThought))
    }

    @Test func persistedRecoveryUsesCompletionTimestamp() {
        let draft = Message(
            role: .assistant,
            content: "Recovered response",
            timestamp: .distantPast
        )
        let completionTimestamp = Date(timeIntervalSince1970: 1_000)

        let persisted = recoveredResponseForPersistence(
            draft,
            timestamp: completionTimestamp
        )

        #expect(draft.timestamp == .distantPast)
        #expect(persisted.timestamp == completionTimestamp)
    }

    @Test func recoveredFirstResponseCanGenerateAChatTitle() throws {
        let user = Message(
            role: .user,
            turnId: "turn-1",
            content: "Question"
        )
        let partial = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Partial"
        )
        let recovered = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered response"
        )

        let messages = try #require(recoveredTitleMessages(
            titleState: .placeholder,
            messages: [user, partial],
            response: recovered,
            turnId: "turn-1"
        ))

        #expect(messages.count == 2)
        #expect(messages[1].content == "Recovered response")
        #expect(recoveredTitleMessages(
            titleState: .manual,
            messages: [user, partial],
            response: recovered,
            turnId: "turn-1"
        ) == nil)
    }

    @Test func insertsRecoveredResponseAfterItsUserTurn() {
        let firstUser = Message(
            role: .user,
            turnId: "turn-1",
            content: "First question"
        )
        let secondUser = Message(
            role: .user,
            turnId: "turn-2",
            content: "Second question"
        )
        let recovered = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered response"
        )

        let messages = mergingRecoveredResponse(
            recovered,
            into: [firstUser, secondUser],
            turnId: "turn-1"
        )

        #expect(messages.map(\.turnId) == ["turn-1", "turn-1", "turn-2"])
        #expect(messages.map(\.role) == [.user, .assistant, .user])
    }

    @Test func replacesOnlyScansThatHaveStoppedMakingProgress() {
        let now = Date(timeIntervalSince1970: 1_000)
        let freshProgress = now.addingTimeInterval(
            -Constants.ChatRecovery.scanStallTimeoutSeconds + 1
        )
        let staleProgress = now.addingTimeInterval(
            -Constants.ChatRecovery.scanStallTimeoutSeconds
        )

        #expect(!recoveryScanHasStalled(lastProgressAt: nil, now: now))
        #expect(!recoveryScanHasStalled(lastProgressAt: freshProgress, now: now))
        #expect(recoveryScanHasStalled(lastProgressAt: staleProgress, now: now))
    }

    @Test func retryDelayUsesACappedExponentialBackoff() {
        #expect(
            chatRecoveryRetryDelayNanoseconds(attempt: 0)
                == Constants.ChatRecovery.retryBaseDelayNanoseconds
        )
        #expect(
            chatRecoveryRetryDelayNanoseconds(attempt: 1)
                == Constants.ChatRecovery.retryBaseDelayNanoseconds * 2
        )
        #expect(
            chatRecoveryRetryDelayNanoseconds(attempt: 100)
                == Constants.ChatRecovery.retryMaxDelayNanoseconds
        )
    }

    @Test func recoveredPayloadComparisonIgnoresDerivedMetadata() {
        var persisted = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered response",
            modelDisplayName: "Model A",
            generationTimeSeconds: 1
        )
        persisted.thinkingDuration = 1
        persisted.timeline = [.string("platform-derived")]
        persisted.searchReasoning = "platform-derived"
        var reconstructed = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered response",
            modelDisplayName: "Model A",
            generationTimeSeconds: 2
        )
        reconstructed.thinkingDuration = 2
        reconstructed.segments = []
        reconstructed.webSearches = []
        reconstructed.timeline = []
        reconstructed.annotations = []

        #expect(recoveryResponsePayloadMatches(persisted, reconstructed))
        reconstructed.content = "Different response"
        #expect(!recoveryResponsePayloadMatches(persisted, reconstructed))
        reconstructed.content = persisted.content
        reconstructed.modelDisplayName = "Different Model"
        #expect(!recoveryResponsePayloadMatches(persisted, reconstructed))
        persisted.modelDisplayName = nil
        #expect(recoveryResponsePayloadMatches(persisted, reconstructed))
    }

    @Test func registrationCleanupRequiresADefinitePreCommitFailure() {
        #expect(registrationFailureDefinitelyDidNotPersist(
            ChatRecoverySyncError.chatMissing
        ))
        #expect(registrationFailureDefinitelyDidNotPersist(
            ChatRecoverySyncError.pendingLimitReached
        ))
        #expect(registrationFailureDefinitelyDidNotPersist(
            ChatRecoverySyncError.conflict
        ))
        #expect(registrationFailureDefinitelyDidNotPersist(
            SyncEnclaveError(message: "conflict", status: 409, code: nil)
        ))
        #expect(!registrationFailureDefinitelyDidNotPersist(
            CancellationError()
        ))
        #expect(!registrationFailureDefinitelyDidNotPersist(
            NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost
            )
        ))
    }

    @Test @MainActor
    func cancellationImmediatelyInvalidatesLiveAttempt() async throws {
        let coordinator = ChatRecoveryCoordinator()
        let attempt = try await coordinator.begin(
            chatId: "chat-1",
            turnId: "turn-1",
            userId: "user-1",
            storage: .cloud
        )

        await coordinator.markCancelled(attempt: attempt)

        let isCurrent = await coordinator.liveAttemptIsCurrent(attempt)
        #expect(isCurrent == false)
    }

    @Test func remoteResolutionRequiresFinalAssistantContent() {
        let placeholder = Message(
            role: .assistant,
            turnId: "turn-1",
            content: ""
        )
        let completed = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered"
        )
        let envelope = PendingRecoveryEnvelope(
            v: 1,
            turnId: "turn-1",
            keyId: "key",
            createdAt: "2026-08-11T00:00:00Z",
            expiresAt: "2026-08-12T00:00:00Z",
            nonce: "nonce",
            ciphertext: "ciphertext"
        )

        #expect(!remoteRecoveryTurnIsResolved(
            messages: [placeholder],
            pendingRecoveries: nil,
            turnId: "turn-1"
        ))
        #expect(remoteRecoveryTurnIsResolved(
            messages: [completed],
            pendingRecoveries: nil,
            turnId: "turn-1"
        ))
        #expect(!remoteRecoveryTurnIsResolved(
            messages: [completed],
            pendingRecoveries: [envelope],
            turnId: "turn-1"
        ))
    }

    @Test func locallyModifiedResolutionRequiresRemoteClockWin() {
        let now = Date()

        #expect(!resolvedRemoteMayReplaceLocal(
            localModified: true,
            localClock: nil,
            remoteClock: EditClock(v: 2, w: "remote"),
            localUpdatedAt: now,
            remoteUpdatedAt: now
        ))
        #expect(resolvedRemoteMayReplaceLocal(
            localModified: true,
            localClock: EditClock(v: 1, w: "local"),
            remoteClock: EditClock(v: 2, w: "remote"),
            localUpdatedAt: now,
            remoteUpdatedAt: now
        ))
        #expect(!resolvedRemoteMayReplaceLocal(
            localModified: true,
            localClock: EditClock(v: 2, w: "local"),
            remoteClock: EditClock(v: 1, w: "remote"),
            localUpdatedAt: now,
            remoteUpdatedAt: now
        ))
    }

    @Test @MainActor
    func corruptedCloudChatIsRejectedBeforeRecoveryMutation() {
        var chat = Chat(modelType: recoverySchedulingTestModel)
        chat.decryptionFailed = true
        var mutationApplied = false

        #expect(throws: ChatRecoverySyncError.self) {
            _ = try mutateValidCloudRecoveryChat(chat) { candidate in
                mutationApplied = true
                candidate.title = "Mutated"
            }
        }
        #expect(!mutationApplied)

        chat.decryptionFailed = false
        chat.dataCorrupted = true
        #expect(throws: ChatRecoverySyncError.self) {
            _ = try mutateValidCloudRecoveryChat(chat) { candidate in
                mutationApplied = true
                candidate.title = "Mutated"
            }
        }
        #expect(!mutationApplied)
    }
}

private let recoverySchedulingTestModel = ModelType(
    from: AppModelConfig(
        modelName: "gpt-oss-120b",
        image: "openai.png",
        name: "GPT OSS 120B",
        nameShort: "GPT OSS",
        description: "",
        details: "",
        parameters: "",
        contextWindow: "64k tokens",
        type: "chat",
        chat: true,
        paid: false,
        multimodal: false,
        toolCalling: nil,
        attributes: nil,
        reasoningConfig: nil
    )
)
