import Testing
@testable import TinfoilChat

struct PendingResponseRecoveryPresentationTests {
    private let recovery = PendingRecoveryEnvelope(
        v: 1,
        turnId: "turn-1",
        keyId: String(repeating: "0", count: 32),
        createdAt: "2026-07-21T00:00:00.000Z",
        expiresAt: "2026-07-22T00:00:00.000Z",
        nonce: "nonce",
        ciphertext: "ciphertext"
    )

    @Test func showsRecoveryForMatchingUserTurn() {
        let message = Message(role: .user, turnId: "turn-1", content: "Question")

        #expect(shouldShowPendingResponseRecovery(
            message: message,
            pendingRecoveries: [recovery],
            activeTurnId: nil
        ))
    }

    @Test func hidesRecoveryForAssistantAndUnrelatedTurns() {
        let assistant = Message(role: .assistant, turnId: "turn-1", content: "")
        let otherUser = Message(role: .user, turnId: "turn-2", content: "Question")

        #expect(!shouldShowPendingResponseRecovery(
            message: assistant,
            pendingRecoveries: [recovery],
            activeTurnId: nil
        ))
        #expect(!shouldShowPendingResponseRecovery(
            message: otherUser,
            pendingRecoveries: [recovery],
            activeTurnId: nil
        ))
    }

    @Test func hidesRecoveryForActiveStreamingTurn() {
        let message = Message(role: .user, turnId: "turn-1", content: "Question")

        #expect(!shouldShowPendingResponseRecovery(
            message: message,
            pendingRecoveries: [recovery],
            activeTurnId: "turn-1"
        ))
    }
}
