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
    case state(ChatRecoveryState)
}

struct RecoverableChatStream {
    let stream: AsyncThrowingStream<ChatStreamResult, Error>
    let token: ChatRecoveryTokenPayload
}

actor ChatRecoveryClient {
    static let shared = ChatRecoveryClient()

    private struct StatusResponse: Decodable {
        let status: ChatRecoveryState
    }

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
            throw ChatRecoveryClientError.httpStatus(response.response.statusCode)
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

    func state(sessionId: String) async throws -> ChatRecoveryState {
        let response = try await request(sessionId: sessionId, suffix: "/status")
        switch response.statusCode {
        case 404:
            return .missing
        case 410:
            return .failed
        default:
            guard (200..<300).contains(response.statusCode),
                  let status = try? JSONDecoder().decode(StatusResponse.self, from: response.data)
            else {
                throw ChatRecoveryClientError.invalidResponse
            }
            return status.status
        }
    }

    func fetch(
        sessionId: String,
        token: ChatRecoveryTokenFields
    ) async throws -> AsyncThrowingStream<ChatStreamResult, Error> {
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
        switch response.statusCode {
        case 404:
            bytes.task.cancel()
            throw ChatRecoveryClientError.state(.missing)
        case 409:
            bytes.task.cancel()
            throw ChatRecoveryClientError.state(.processing)
        case 410:
            bytes.task.cancel()
            throw ChatRecoveryClientError.state(.failed)
        case let statusCode where !(200..<300).contains(statusCode):
            bytes.task.cancel()
            throw ChatRecoveryClientError.httpStatus(statusCode)
        default:
            guard let nonceHex = response.value(
                      forHTTPHeaderField: EHBPProtocol.responseNonceHeader
                  ),
                  nonceHex == nonceHex.lowercased(),
                  let nonce = Data(lowercaseHex: nonceHex),
                  nonce.count == EHBPConstants.responseNonceLength
            else {
                bytes.task.cancel()
                throw ChatRecoveryClientError.invalidResponse
            }
            let responseDecryptor = try SessionRecoveryToken(
                exportedSecret: exportedSecret,
                requestEnc: requestEnc
            ).makeResponseDecryptor(
                responseNonce: nonce
            )
            let plaintext = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    do {
                        var decryptor = responseDecryptor
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            for chunk in try decryptor.push(Data([byte])) {
                                continuation.yield(chunk)
                            }
                        }
                        try decryptor.finish()
                        continuation.finish()
                    } catch {
                        bytes.task.cancel()
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    bytes.task.cancel()
                }
            }
            return Self.decodeSSE(plaintext)
        }
    }

    func delete(sessionId: String) async throws {
        let response = try await request(sessionId: sessionId, method: "DELETE")
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
            throw ChatRecoveryClientError.invalidResponse
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

    private static func decodeSSE(
        _ byteStream: AsyncThrowingStream<Data, Error>
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
                            guard let payload = event.ssePayload, payload != "[DONE]" else {
                                continue
                            }
                            let result = try JSONDecoder().decode(
                                ChatStreamResult.self,
                                from: Data(payload.utf8)
                            )
                            continuation.yield(result)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
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
