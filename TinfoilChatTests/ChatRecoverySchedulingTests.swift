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
}
