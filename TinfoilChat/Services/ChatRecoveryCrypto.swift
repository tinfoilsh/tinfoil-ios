import CryptoKit
import Foundation

enum ChatRecoveryCryptoError: Error, Equatable {
    case invalidEnvelope
    case invalidIdentifier
    case invalidKey
    case expired
    case decryptionFailed
}

struct ChatRecoveryTokenFields: Codable, Equatable, Sendable {
    let exportedSecret: String
    let requestEnc: String
}

enum ChatRecoveryTokenPayload: Codable, Equatable, Sendable {
    case serialized(String)
    case fields(ChatRecoveryTokenFields)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let serialized = try? container.decode(String.self) {
            self = .serialized(serialized)
        } else {
            self = .fields(try container.decode(ChatRecoveryTokenFields.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .serialized(let value):
            try container.encode(value)
        case .fields(let value):
            try container.encode(value)
        }
    }

    var fields: ChatRecoveryTokenFields? {
        switch self {
        case .fields(let value):
            return value
        case .serialized(let value):
            guard let data = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ChatRecoveryTokenFields.self, from: data)
        }
    }
}

struct ChatRecoveryEnvelopePayload: Codable, Equatable, Sendable {
    let sessionId: String
    let recoveryToken: ChatRecoveryTokenPayload
}

enum ChatRecoveryCrypto {
    private static let base64DecodedBlockBytes = 3
    private static let base64EncodedBlockCharacters = 4

    private static func timestampFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    static func encrypt(
        cek: Data,
        userId: String,
        chatId: String,
        turnId: String,
        sessionId: String,
        recoveryToken: ChatRecoveryTokenPayload,
        now: Date = Date()
    ) throws -> PendingRecoveryEnvelope {
        try requireIdentifier(userId)
        try requireIdentifier(chatId)
        try requireIdentifier(turnId)
        try requireLowercaseHex(sessionId, length: Constants.ChatRecovery.sessionIdBytes * 2)
        try requireToken(recoveryToken)

        let keyId = try recoveryKeyId(cek)
        let formatter = timestampFormatter(fractionalSeconds: true)
        let createdAt = formatter.string(from: now)
        let expiresAt = formatter.string(
            from: now.addingTimeInterval(Constants.ChatRecovery.envelopeLifetimeSeconds)
        )
        let metadata = PendingRecoveryEnvelope(
            v: Constants.ChatRecovery.envelopeVersion,
            turnId: turnId,
            keyId: keyId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            nonce: "",
            ciphertext: ""
        )
        let payload = ChatRecoveryEnvelopePayload(
            sessionId: sessionId,
            recoveryToken: recoveryToken
        )
        let plaintext = try JSONEncoder().encode(payload)
        let key = try envelopeKey(cek)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: try aad(userId: userId, chatId: chatId, envelope: metadata)
        )
        let envelope = PendingRecoveryEnvelope(
            v: metadata.v,
            turnId: metadata.turnId,
            keyId: metadata.keyId,
            createdAt: metadata.createdAt,
            expiresAt: metadata.expiresAt,
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
        try validate(envelope)
        return envelope
    }

    static func decrypt(
        cek: Data,
        userId: String,
        chatId: String,
        envelope: PendingRecoveryEnvelope,
        now: Date = Date()
    ) throws -> ChatRecoveryEnvelopePayload {
        try requireIdentifier(userId)
        try requireIdentifier(chatId)
        try validate(envelope)
        guard try recoveryKeyId(cek) == envelope.keyId else {
            throw ChatRecoveryCryptoError.invalidKey
        }
        guard let expiry = parseTimestamp(envelope.expiresAt), now < expiry else {
            throw ChatRecoveryCryptoError.expired
        }
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let combinedCiphertext = Data(base64Encoded: envelope.ciphertext),
              combinedCiphertext.count > Constants.ChatRecovery.authenticationTagBytes
        else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }

        do {
            let tagStart = combinedCiphertext.count - Constants.ChatRecovery.authenticationTagBytes
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: combinedCiphertext[..<tagStart],
                tag: combinedCiphertext[tagStart...]
            )
            let plaintext = try AES.GCM.open(
                sealed,
                using: try envelopeKey(cek),
                authenticating: try aad(userId: userId, chatId: chatId, envelope: envelope)
            )
            let payload = try JSONDecoder().decode(ChatRecoveryEnvelopePayload.self, from: plaintext)
            try requireLowercaseHex(
                payload.sessionId,
                length: Constants.ChatRecovery.sessionIdBytes * 2
            )
            try requireToken(payload.recoveryToken)
            return payload
        } catch let error as ChatRecoveryCryptoError {
            throw error
        } catch {
            throw ChatRecoveryCryptoError.decryptionFailed
        }
    }

    static func rewrap(
        envelope: PendingRecoveryEnvelope,
        userId: String,
        chatId: String,
        oldCEK: Data,
        newCEK: Data,
        now: Date = Date()
    ) throws -> PendingRecoveryEnvelope {
        let payload = try decrypt(
            cek: oldCEK,
            userId: userId,
            chatId: chatId,
            envelope: envelope,
            now: now
        )
        let keyId = try recoveryKeyId(newCEK)
        let metadata = PendingRecoveryEnvelope(
            v: envelope.v,
            turnId: envelope.turnId,
            keyId: keyId,
            createdAt: envelope.createdAt,
            expiresAt: envelope.expiresAt,
            nonce: "",
            ciphertext: ""
        )
        let plaintext = try JSONEncoder().encode(payload)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: try envelopeKey(newCEK),
            nonce: nonce,
            authenticating: try aad(userId: userId, chatId: chatId, envelope: metadata)
        )
        let rewrapped = PendingRecoveryEnvelope(
            v: metadata.v,
            turnId: metadata.turnId,
            keyId: metadata.keyId,
            createdAt: metadata.createdAt,
            expiresAt: metadata.expiresAt,
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
        try validate(rewrapped)
        return rewrapped
    }

    static func validate(_ envelope: PendingRecoveryEnvelope) throws {
        guard envelope.v == Constants.ChatRecovery.envelopeVersion else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }
        try requireIdentifier(envelope.turnId)
        try requireLowercaseHex(
            envelope.keyId,
            length: Constants.ChatRecovery.keyIdHexLength
        )
        guard let createdAt = parseTimestamp(envelope.createdAt),
              let expiresAt = parseTimestamp(envelope.expiresAt),
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= Constants.ChatRecovery.envelopeLifetimeSeconds
        else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }
        guard let nonce = canonicalBase64(
                  envelope.nonce,
                  maxDecodedBytes: Constants.ChatRecovery.nonceBytes
              ),
              nonce.count == Constants.ChatRecovery.nonceBytes,
              let ciphertext = canonicalBase64(
                  envelope.ciphertext,
                  maxDecodedBytes: Constants.ChatRecovery.maxCiphertextBytes
              ),
              ciphertext.count > Constants.ChatRecovery.authenticationTagBytes,
              ciphertext.count <= Constants.ChatRecovery.maxCiphertextBytes
        else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }
    }

    static func isExpired(
        _ envelope: PendingRecoveryEnvelope,
        now: Date = Date()
    ) throws -> Bool {
        try validate(envelope)
        guard let expiry = parseTimestamp(envelope.expiresAt) else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }
        return now >= expiry
    }

    private static func envelopeKey(_ cek: Data) throws -> SymmetricKey {
        guard cek.count == Constants.ChatRecovery.cekBytes else {
            throw ChatRecoveryCryptoError.invalidKey
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: cek),
            salt: Data(),
            info: Data(Constants.ChatRecovery.hkdfInfo.utf8),
            outputByteCount: Constants.ChatRecovery.cekBytes
        )
    }

    private static func aad(
        userId: String,
        chatId: String,
        envelope: PendingRecoveryEnvelope
    ) throws -> Data {
        try requireIdentifier(userId)
        try requireIdentifier(chatId)
        return try JSONSerialization.data(
            withJSONObject: [
                Constants.ChatRecovery.aadLabel,
                userId,
                chatId,
                envelope.turnId,
                envelope.keyId,
                envelope.v,
                envelope.createdAt,
                envelope.expiresAt,
            ],
            options: [.withoutEscapingSlashes]
        )
    }

    private static func requireIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= Constants.ChatRecovery.maxIdentifierLength
        else {
            throw ChatRecoveryCryptoError.invalidIdentifier
        }
    }

    private static func recoveryKeyId(_ cek: Data) throws -> String {
        do {
            return try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            throw ChatRecoveryCryptoError.invalidKey
        }
    }

    private static func requireToken(_ token: ChatRecoveryTokenPayload) throws {
        guard let fields = token.fields else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }
        try requireLowercaseHex(
            fields.exportedSecret,
            length: Constants.ChatRecovery.tokenFieldHexLength
        )
        try requireLowercaseHex(
            fields.requestEnc,
            length: Constants.ChatRecovery.tokenFieldHexLength
        )
    }

    private static func requireLowercaseHex(_ value: String, length: Int) throws {
        guard value.count == length,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains(Int($0.value))
                      || (97...102).contains(Int($0.value))
              })
        else {
            throw ChatRecoveryCryptoError.invalidEnvelope
        }
    }

    private static func canonicalBase64(
        _ value: String,
        maxDecodedBytes: Int
    ) -> Data? {
        let maxEncodedCharacters = (
            (maxDecodedBytes + base64DecodedBlockBytes - 1) / base64DecodedBlockBytes
        ) * base64EncodedBlockCharacters
        guard !value.isEmpty,
              value.utf8.count <= maxEncodedCharacters,
              let data = Data(base64Encoded: value),
              data.base64EncodedString() == value
        else {
            return nil
        }
        return data
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        timestampFormatter(fractionalSeconds: true).date(from: value)
            ?? timestampFormatter(fractionalSeconds: false).date(from: value)
    }
}
