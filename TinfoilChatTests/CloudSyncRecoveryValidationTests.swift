import Foundation
import Testing
@testable import TinfoilChat

@Suite("Cloud recovery validation")
struct CloudSyncRecoveryValidationTests {
    @Test func acceptsValidRecoveryEnvelopes() throws {
        let envelope = try makeEnvelope()

        let chat = try JSONDecoder().decode(
            StoredChat.self,
            from: storedChatData(pendingRecoveries: [envelope])
        )

        #expect(chat.pendingRecoveries == [envelope])
    }

    @Test func rejectsDuplicateRecoveryTurns() throws {
        let envelope = try makeEnvelope()

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                StoredChat.self,
                from: storedChatData(
                    pendingRecoveries: [envelope, envelope]
                )
            )
        }
    }

    @Test func rejectsTooManyRecoveryEnvelopes() throws {
        let envelope = try makeEnvelope()

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                StoredChat.self,
                from: storedChatData(
                    pendingRecoveries: Array(
                        repeating: envelope,
                        count: Constants.ChatRecovery.maxPendingPerChat + 1
                    )
                )
            )
        }
    }

    @Test func rejectsInvalidRecoveryMetadata() throws {
        let envelope = try makeEnvelope()
        let invalid = PendingRecoveryEnvelope(
            v: envelope.v,
            turnId: "",
            keyId: envelope.keyId,
            createdAt: envelope.createdAt,
            expiresAt: envelope.expiresAt,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                StoredChat.self,
                from: storedChatData(pendingRecoveries: [invalid])
            )
        }
    }

    private func makeEnvelope() throws -> PendingRecoveryEnvelope {
        try ChatRecoveryCrypto.encrypt(
            cek: Data(repeating: 1, count: SyncEnclaveKeyBundle.cekByteCount),
            userId: "user_123",
            chatId: "chat_123",
            turnId: "turn_123",
            sessionId: "0123456789abcdef0123456789abcdef",
            recoveryToken: .fields(ChatRecoveryTokenFields(
                exportedSecret: String(repeating: "a", count: 64),
                requestEnc: String(repeating: "b", count: 64)
            )),
            now: ISO8601DateFormatter().date(
                from: "2026-07-20T12:00:00Z"
            )!
        )
    }

    private func storedChatData(
        pendingRecoveries: [PendingRecoveryEnvelope]
    ) throws -> Data {
        let pendingData = try JSONEncoder().encode(pendingRecoveries)
        let pendingJSON = try JSONSerialization.jsonObject(with: pendingData)
        return try JSONSerialization.data(withJSONObject: [
            "id": "chat_123",
            "title": "Chat",
            "messages": [],
            "pendingRecoveries": pendingJSON,
            "createdAt": "2026-07-20T12:00:00.000Z",
            "updatedAt": "2026-07-20T12:00:00.000Z",
            "syncVersion": 1,
            "locallyModified": false,
        ])
    }
}
