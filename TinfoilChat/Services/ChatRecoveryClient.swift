@preconcurrency import EHBP
import Foundation
import Security
@preconcurrency import TinfoilAI

enum ChatRecoveryState: String, Decodable, Sendable {
    case processing
    case complete
    case failed
    case missing
}

enum ChatRecoveryClientError: Error {
    case invalidSession
    case unavailable
    case invalidResponse
    case httpStatus(Int)
    case httpResponse(Int, String)
    case state(ChatRecoveryState)

    var statusCode: Int? {
        switch self {
        case .httpStatus(let statusCode), .httpResponse(let statusCode, _):
            return statusCode
        default:
            return nil
        }
    }
}

extension ChatRecoveryClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .httpResponse(_, let body) where !body.isEmpty:
            return body
        case .httpStatus(let statusCode), .httpResponse(let statusCode, _):
            return "Request failed with status \(statusCode)."
        case .invalidSession:
            return "The recovery session is invalid."
        case .unavailable:
            return "Response recovery is unavailable."
        case .invalidResponse:
            return "The recovery service returned an invalid response."
        case .state(let state):
            return "Response recovery is \(state.rawValue)."
        }
    }
}

struct RecoverableChatStream {
    let stream: AsyncThrowingStream<ChatStreamResult, Error>
    let token: ChatRecoveryTokenPayload
}

struct RecoveredChatStream {
    let stream: AsyncThrowingStream<ChatStreamResult, Error>
    let statusCode: Int
    let encryptedByteCount: @Sendable () async -> Int
}

struct ChatRecoveryStatus: Decodable, Sendable {
    let state: ChatRecoveryState
    let persistedBytes: Int

    private enum CodingKeys: String, CodingKey {
        case state = "status"
        case persistedBytes = "bytes"
    }

    init(state: ChatRecoveryState, persistedBytes: Int) {
        self.state = state
        self.persistedBytes = persistedBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(ChatRecoveryState.self, forKey: .state)
        persistedBytes = try container.decode(Int.self, forKey: .persistedBytes)
        guard persistedBytes >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .persistedBytes,
                in: container,
                debugDescription: "Persisted byte count must not be negative"
            )
        }
    }
}

private actor ChatRecoveryByteCounter {
    private var count = 0

    func set(_ count: Int) {
        self.count = count
    }

    func value() -> Int {
        count
    }
}

actor ChatRecoveryClient {
    static let shared = ChatRecoveryClient()

    private var verifiedEndpoint: (enclaveURL: String, publicKey: Data)?

    func start(
        query: ChatQuery,
        sessionId: String,
        bearerToken: String,
        userId: String
    ) async throws -> RecoverableChatStream {
        try validateSessionId(sessionId)
        let endpoint = try await endpoint()
        let client = try EHBPClient(
            baseURL: Constants.API.baseURL,
            publicKey: endpoint.publicKey
        )
        var streamingQuery = query
        streamingQuery.stream = true
        let encodedQuery = try JSONEncoder().encode(streamingQuery)
        guard var bodyObject = try JSONSerialization.jsonObject(
            with: encodedQuery
        ) as? [String: Any] else {
            throw ChatRecoveryClientError.invalidResponse
        }
        bodyObject["user_cache_secret"] = try promptCacheSecret(userId: userId)
        let body = try JSONSerialization.data(withJSONObject: bodyObject)
        let response = try await client.requestStream(
            method: "POST",
            path: Constants.API.chatCompletionsEndpoint,
            headers: [
                "Authorization": "Bearer \(bearerToken)",
                "Content-Type": "application/json",
                Constants.ChatRecovery.sessionHeader: sessionId,
                Constants.ChatRecovery.eventsHeader: Constants.ChatRecovery.webSearchEvent,
                Constants.ChatRecovery.enclaveHeader: endpoint.enclaveURL,
            ],
            body: body
        )
        guard (200..<300).contains(response.response.statusCode) else {
            var body = Data()
            for try await chunk in response.stream {
                body.append(chunk)
            }
            throw recoveryHTTPError(statusCode: response.response.statusCode, data: body)
        }
        let token = try client.getSessionRecoveryToken()
        let tokenFields = ChatRecoveryTokenFields(
            exportedSecret: token.exportedSecret.hexEncodedString(),
            requestEnc: token.requestEnc.hexEncodedString()
        )
        let serialized = String(
            data: try JSONEncoder().encode(tokenFields),
            encoding: .utf8
        )
        guard let serialized else {
            throw ChatRecoveryClientError.invalidResponse
        }
        return RecoverableChatStream(
            stream: Self.decodeSSE(response.stream),
            token: .serialized(serialized)
        )
    }

    func status(sessionId: String) async throws -> ChatRecoveryStatus {
        let response = try await request(sessionId: sessionId, suffix: "/status")
        switch response.statusCode {
        case 404:
            return ChatRecoveryStatus(state: .missing, persistedBytes: 0)
        case 410:
            return ChatRecoveryStatus(state: .failed, persistedBytes: 0)
        default:
            guard (200..<300).contains(response.statusCode),
                  let status = try? JSONDecoder().decode(
                      ChatRecoveryStatus.self,
                      from: response.data
                  )
            else {
                if !(200..<300).contains(response.statusCode) {
                    throw recoveryHTTPError(statusCode: response.statusCode, data: response.data)
                }
                throw ChatRecoveryClientError.invalidResponse
            }
            return status
        }
    }

    func fetch(
        sessionId: String,
        token: ChatRecoveryTokenFields
    ) async throws -> RecoveredChatStream {
        guard let exportedSecret = Data(lowercaseHex: token.exportedSecret),
              exportedSecret.count == EHBPConstants.exportLength,
              let requestEnc = Data(lowercaseHex: token.requestEnc),
              requestEnc.count == EHBPConstants.requestEncLength
        else {
            throw ChatRecoveryClientError.invalidResponse
        }
        let request = try await recoveryRequest(sessionId: sessionId)
        let (bytes, urlResponse) = try await URLSession.shared.bytes(for: request)
        guard let response = urlResponse as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ChatRecoveryClientError.invalidResponse
        }
        if response.statusCode == 404 {
            bytes.task.cancel()
            throw ChatRecoveryClientError.state(.missing)
        }
        if response.statusCode == 410 {
            bytes.task.cancel()
            throw ChatRecoveryClientError.state(.failed)
        }
        if !(200..<300).contains(response.statusCode),
           response.value(forHTTPHeaderField: EHBPProtocol.responseNonceHeader) == nil {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            throw recoveryHTTPError(statusCode: response.statusCode, data: body)
        }
        let nonce: Data
        do {
            nonce = try recoveryResponseNonce(from: response)
        } catch {
            bytes.task.cancel()
            throw error
        }
        let responseDecryptor = try SessionRecoveryToken(
            exportedSecret: exportedSecret,
            requestEnc: requestEnc
        ).makeResponseDecryptor(
            responseNonce: nonce
        )
        let byteCounter = ChatRecoveryByteCounter()
        let plaintext = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var encryptedByteCount = 0
                do {
                    var decryptor = responseDecryptor
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        encryptedByteCount += 1
                        if let chunk = try decryptor.push(byte) {
                            continuation.yield(chunk)
                        }
                    }
                    try decryptor.finish()
                    await byteCounter.set(encryptedByteCount)
                    continuation.finish()
                } catch {
                    await byteCounter.set(encryptedByteCount)
                    bytes.task.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return RecoveredChatStream(
            stream: Self.decodeSSE(plaintext, statusCode: response.statusCode),
            statusCode: response.statusCode,
            encryptedByteCount: {
                await byteCounter.value()
            }
        )
    }

    func delete(sessionId: String) async throws {
        let response = try await request(sessionId: sessionId, method: "DELETE")
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
            throw recoveryHTTPError(statusCode: response.statusCode, data: response.data)
        }
    }

    private func endpoint() async throws -> (enclaveURL: String, publicKey: Data) {
        if let verifiedEndpoint {
            return verifiedEndpoint
        }
        let verifier = SecureClient()
        let groundTruth = try await verifier.verify()
        guard let url = verifier.verifiedEnclaveURL,
              let keyHex = groundTruth.hpkePublicKey,
              let publicKey = Data(lowercaseHex: keyHex),
              publicKey.count == Constants.ChatRecovery.cekBytes
        else {
            throw ChatRecoveryClientError.unavailable
        }
        let endpoint = (enclaveURL: url, publicKey: publicKey)
        verifiedEndpoint = endpoint
        return endpoint
    }

    private func promptCacheSecret(userId: String) throws -> String {
        let key = "\(Constants.ChatRecovery.userCacheKeyPrefix)-\(userId)"
        if let existing = KeychainHelper.shared.loadString(for: key), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: Constants.ChatRecovery.cekBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatRecoveryClientError.unavailable
        }
        let secret = Data(bytes).base64EncodedString()
        guard KeychainHelper.shared.save(secret, for: key) else {
            throw ChatRecoveryClientError.unavailable
        }
        return secret
    }

    private func request(
        sessionId: String,
        suffix: String = "",
        method: String = "GET"
    ) async throws -> (data: Data, statusCode: Int, headers: [String: String]) {
        let request = try await recoveryRequest(
            sessionId: sessionId,
            suffix: suffix,
            method: method
        )
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else {
            throw ChatRecoveryClientError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return (data, response.statusCode, headers)
    }

    private func recoveryRequest(
        sessionId: String,
        suffix: String = "",
        method: String = "GET"
    ) async throws -> URLRequest {
        try validateSessionId(sessionId)
        _ = try await endpoint()
        guard let baseURL = URL(string: Constants.API.baseURL),
              let url = URL(
                string: "\(Constants.ChatRecovery.statusPathPrefix)/\(sessionId)\(suffix)",
                relativeTo: baseURL
              )
        else {
            throw ChatRecoveryClientError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Constants.ChatRecovery.requestTimeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func validateSessionId(_ sessionId: String) throws {
        guard sessionId.count == Constants.ChatRecovery.sessionIdBytes * 2,
              Data(lowercaseHex: sessionId) != nil
        else {
            throw ChatRecoveryClientError.invalidSession
        }
    }

    static func decodeSSE(
        _ byteStream: AsyncThrowingStream<Data, Error>,
        statusCode: Int? = nil
    ) -> AsyncThrowingStream<ChatStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await chunk in byteStream {
                        try Task.checkCancellation()
                        buffer.append(chunk)
                        while let boundary = buffer.eventBoundary {
                            let event = buffer.prefix(boundary.lowerBound)
                            buffer.removeSubrange(..<boundary.upperBound)
                            if let result = try decodeRecoveryEvent(event, statusCode: statusCode) {
                                continuation.yield(result)
                            }
                        }
                    }
                    if !buffer.isEmpty,
                       let result = try decodeRecoveryEvent(buffer, statusCode: statusCode) {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decodeRecoveryEvent(
        _ event: Data,
        statusCode: Int?
    ) throws -> ChatStreamResult? {
        let payload: String?
        if let ssePayload = event.ssePayload {
            payload = ssePayload
        } else if let statusCode, !(200..<300).contains(statusCode) {
            payload = String(data: event, encoding: .utf8)
        } else {
            return nil
        }
        guard let payload, !payload.isEmpty, payload != "[DONE]" else { return nil }
        do {
            return try JSONDecoder().decode(ChatStreamResult.self, from: Data(payload.utf8))
        } catch {
            if let statusCode, !(200..<300).contains(statusCode) {
                throw recoveryHTTPError(statusCode: statusCode, data: Data(payload.utf8))
            }
            throw error
        }
    }
}

func recoveryHTTPError(statusCode: Int, data: Data) -> ChatRecoveryClientError {
    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let payload = data.ssePayload ?? raw
    let payloadData = Data(payload.utf8)
    if let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return .httpResponse(statusCode, message)
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return .httpResponse(statusCode, message)
        }
    }
    if !payload.isEmpty {
        return .httpResponse(statusCode, payload)
    }
    return .httpStatus(statusCode)
}

func recoveryResponseNonce(from response: HTTPURLResponse) throws -> Data {
    guard let nonceHex = response.value(
        forHTTPHeaderField: EHBPProtocol.responseNonceHeader
    ) else {
        switch response.statusCode {
        case 404:
            throw ChatRecoveryClientError.state(.missing)
        case 410:
            throw ChatRecoveryClientError.state(.failed)
        case let statusCode where !(200..<300).contains(statusCode):
            throw ChatRecoveryClientError.httpStatus(statusCode)
        default:
            throw ChatRecoveryClientError.invalidResponse
        }
    }
    guard nonceHex == nonceHex.lowercased(),
          let nonce = Data(lowercaseHex: nonceHex),
          nonce.count == EHBPConstants.responseNonceLength
    else {
        throw ChatRecoveryClientError.invalidResponse
    }
    return nonce
}

private extension Data {
    init?(lowercaseHex: String) {
        guard lowercaseHex.count.isMultiple(of: 2),
              lowercaseHex.unicodeScalars.allSatisfy({
                  (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
              })
        else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lowercaseHex.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }

    var eventBoundary: Range<Data.Index>? {
        [
            range(of: Data("\r\n\r\n".utf8)),
            range(of: Data("\n\n".utf8)),
            range(of: Data("\r\r".utf8)),
        ]
        .compactMap { $0 }
        .min(by: { $0.lowerBound < $1.lowerBound })
    }

    var ssePayload: String? {
        guard let string = String(data: self, encoding: .utf8) else { return nil }
        let values = string
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Substring? in
                guard line.hasPrefix("data:") else { return nil }
                return line.dropFirst(5).drop(while: { $0 == " " })
            }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: "\n")
    }
}
