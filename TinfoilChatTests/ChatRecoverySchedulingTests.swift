import Foundation
import Testing
@testable import TinfoilChat

struct ChatRecoverySchedulingTests {
    @Test func emptyThinkingDraftDoesNotReplaceRecoveryIndicator() {
        let emptyThinking = Message(
            role: .assistant,
            content: "",
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
}
