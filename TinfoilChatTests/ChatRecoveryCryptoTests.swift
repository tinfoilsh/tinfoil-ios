import Foundation
import Testing
@testable import TinfoilChat

@Suite("Chat recovery envelope crypto")
struct ChatRecoveryCryptoTests {
    private let userId = "user_123"
    private let chatId = "chat_123"
    private let turnId = "turn_123"
    private let sessionId = "0123456789abcdef0123456789abcdef"
    private let now = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!

    private var token: ChatRecoveryTokenFields {
        ChatRecoveryTokenFields(
            exportedSecret: String(repeating: "a", count: 64),
            requestEnc: String(repeating: "b", count: 64)
        )
    }

    @Test("round trips structured and serialized tokens")
    func roundTrip() throws {
        for payload in [
            ChatRecoveryTokenPayload.fields(token),
            .serialized(String(data: try JSONEncoder().encode(token), encoding: .utf8)!),
        ] {
            let envelope = try ChatRecoveryCrypto.encrypt(
                cek: Data(repeating: 1, count: 32),
                userId: userId,
                chatId: chatId,
                turnId: turnId,
                sessionId: sessionId,
                recoveryToken: payload,
                now: now
            )
            let opened = try ChatRecoveryCrypto.decrypt(
                cek: Data(repeating: 1, count: 32),
                userId: userId,
                chatId: chatId,
                envelope: envelope,
                now: now
            )
            #expect(opened.sessionId == sessionId)
            #expect(opened.recoveryToken.fields == token)
        }
    }

    @Test("binds ciphertext to account and turn metadata")
    func authenticatedMetadata() throws {
        let envelope = try makeEnvelope()
        #expect(throws: ChatRecoveryCryptoError.self) {
            try ChatRecoveryCrypto.decrypt(
                cek: Data(repeating: 1, count: 32),
                userId: "another_user",
                chatId: chatId,
                envelope: envelope,
                now: now
            )
        }
        let tampered = PendingRecoveryEnvelope(
            v: envelope.v,
            turnId: "another_turn",
            keyId: envelope.keyId,
            createdAt: envelope.createdAt,
            expiresAt: envelope.expiresAt,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        #expect(throws: ChatRecoveryCryptoError.self) {
            try ChatRecoveryCrypto.decrypt(
                cek: Data(repeating: 1, count: 32),
                userId: userId,
                chatId: chatId,
                envelope: tampered,
                now: now
            )
        }
    }

    @Test("rewrap preserves lifetime and requires the new key")
    func rewrap() throws {
        let envelope = try makeEnvelope()
        let rewrapped = try ChatRecoveryCrypto.rewrap(
            envelope: envelope,
            userId: userId,
            chatId: chatId,
            oldCEK: Data(repeating: 1, count: 32),
            newCEK: Data(repeating: 2, count: 32),
            now: now
        )
        #expect(rewrapped.createdAt == envelope.createdAt)
        #expect(rewrapped.expiresAt == envelope.expiresAt)
        #expect(rewrapped.keyId != envelope.keyId)
        #expect(throws: ChatRecoveryCryptoError.self) {
            try ChatRecoveryCrypto.decrypt(
                cek: Data(repeating: 1, count: 32),
                userId: userId,
                chatId: chatId,
                envelope: rewrapped,
                now: now
            )
        }
        let opened = try ChatRecoveryCrypto.decrypt(
            cek: Data(repeating: 2, count: 32),
            userId: userId,
            chatId: chatId,
            envelope: rewrapped,
            now: now
        )
        #expect(opened.recoveryToken.fields == token)
    }

    @Test("rejects expired envelopes")
    func expiry() throws {
        let envelope = try makeEnvelope()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: envelope.expiresAt)!
        #expect(try ChatRecoveryCrypto.isExpired(envelope, now: expiry))
        #expect(throws: ChatRecoveryCryptoError.expired) {
            try ChatRecoveryCrypto.decrypt(
                cek: Data(repeating: 1, count: 32),
                userId: userId,
                chatId: chatId,
                envelope: envelope,
                now: expiry
            )
        }
    }

    @Test("rejects oversized ciphertext")
    func oversizedCiphertext() throws {
        let envelope = try makeEnvelope()
        let oversized = PendingRecoveryEnvelope(
            v: envelope.v,
            turnId: envelope.turnId,
            keyId: envelope.keyId,
            createdAt: envelope.createdAt,
            expiresAt: envelope.expiresAt,
            nonce: envelope.nonce,
            ciphertext: Data(
                repeating: 0,
                count: Constants.ChatRecovery.maxCiphertextBytes + 1
            ).base64EncodedString()
        )
        #expect(throws: ChatRecoveryCryptoError.invalidEnvelope) {
            try ChatRecoveryCrypto.validate(oversized)
        }
    }

    @Test("round trips cross-device turn metadata")
    func modelRoundTrip() throws {
        let message = Message(
            role: .user,
            turnId: turnId,
            content: "hello"
        )
        let decodedMessage = try JSONDecoder().decode(
            Message.self,
            from: JSONEncoder().encode(message)
        )
        #expect(decodedMessage.turnId == turnId)

        let envelope = try makeEnvelope()
        let decodedEnvelope = try JSONDecoder().decode(
            PendingRecoveryEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        #expect(decodedEnvelope == envelope)
    }

    private func makeEnvelope() throws -> PendingRecoveryEnvelope {
        try ChatRecoveryCrypto.encrypt(
            cek: Data(repeating: 1, count: 32),
            userId: userId,
            chatId: chatId,
            turnId: turnId,
            sessionId: sessionId,
            recoveryToken: .fields(token),
            now: now
        )
    }
}
