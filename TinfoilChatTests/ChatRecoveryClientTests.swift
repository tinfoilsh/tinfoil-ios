@preconcurrency import EHBP
import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

@Suite("Chat recovery client")
struct ChatRecoveryClientTests {
    private func problemResponse(status: Int = 422, type: String = "application/problem+json", length: Int?) throws -> HTTPURLResponse {
        var headers = ["Content-Type": type]
        if let length { headers["Content-Length"] = String(length) }
        return try #require(HTTPURLResponse(
            url: URL(string: "https://example.com/v1/chat/completions")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    @Test func onlyExplicitBoundedKeyRejectionsAllowRefresh() throws {
        let body = Data(#"{"type":"urn:ietf:params:ehbp:error:key-config"}"#.utf8)
        let response = try problemResponse(type: "Application/Problem+JSON; charset=utf-8", length: body.count)
        #expect(ChatRecoveryKeyConfiguration.isMismatch(response: response, body: body))

        for status in [200, 400, 401, 429, 500, 502] {
            let response = try problemResponse(status: status, length: body.count)
            #expect(!ChatRecoveryKeyConfiguration.isMismatch(response: response, body: body))
        }
        for type in ["application/json", "text/html"] {
            let response = try problemResponse(type: type, length: body.count)
            #expect(!ChatRecoveryKeyConfiguration.isMismatch(response: response, body: body))
        }
        let invalidLengths: [Int?] = [nil, body.count - 1, Constants.ChatRecovery.maximumDiagnosticBytes + 1]
        for length in invalidLengths {
            let response = try problemResponse(length: length)
            #expect(!ChatRecoveryKeyConfiguration.isMismatch(response: response, body: body))
        }
        for invalid in [#"{"type":"unrelated"}"#, "{", #"{"type":null}"#] {
            let invalidBody = Data(invalid.utf8)
            let response = try problemResponse(length: invalidBody.count)
            #expect(!ChatRecoveryKeyConfiguration.isMismatch(response: response, body: invalidBody))
        }
    }

    @Test func fragmentedSSEPreservesUnicodeAndCompletion() async throws {
        let content = #"{"id":"response","object":"chat.completion.chunk","created":1,"model":"gpt-oss-120b","choices":[{"index":0,"delta":{"content":"Area π"}}]}"#
        let finish = #"{"id":"response","object":"chat.completion.chunk","created":1,"model":"gpt-oss-120b","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        for separator in ["\n\n", "\r\n\r\n", "\r\r"] {
            let wire = ": keepalive\(separator)data: \(content)\(separator)data: \(finish)\(separator)data: [DONE]\(separator)"
            let bytes = AsyncThrowingStream<Data, Error> { continuation in
                for byte in wire.utf8 { continuation.yield(Data([byte])) }
                continuation.finish()
            }
            let processor = StreamingResponseProcessor(isWebSearchEnabled: false, hapticEnabled: false)
            for try await chunk in ChatRecoveryClient.decodeSSE(bytes) {
                _ = processor.process(processor.parse(chunk))
            }
            try processor.finishStream()
            #expect(processor.snapshot().responseContent == "Area π")
        }
    }

    @Test func serverErrorsKeepTheirTypedDetails() async {
        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: {\"error\":{\"message\":\"Capacity unavailable\",\"type\":\"server_error\",\"code\":\"overloaded\"}}\n\n".utf8))
            continuation.finish()
        }
        do {
            for try await _ in ChatRecoveryClient.decodeSSE(bytes) {}
            Issue.record("Expected a server error")
        } catch let error as APIErrorResponse {
            #expect(error.error.code == "overloaded")
            #expect(error.error.message == "Capacity unavailable")
        } catch {
            Issue.record("Lost server error details: \(error)")
        }
    }

    @Test func providerMetadataUsesSDKCompatibilityOptions() async throws {
        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: {\"id\":null,\"created\":1,\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Answer\"},\"finish_reason\":\"stop\"}]}\n\n".utf8))
            continuation.finish()
        }
        var content = ""
        for try await chunk in ChatRecoveryClient.decodeSSE(bytes) {
            content += chunk.choices.first?.delta.content ?? ""
        }
        #expect(content == "Answer")
    }

    @Test func doneMarkerDoesNotHideTransportIntegrityFailure() async {
        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: [DONE]\n\n".utf8))
            continuation.finish(throwing: ChatRecoveryClientError.invalidResponse)
        }
        do {
            for try await _ in ChatRecoveryClient.decodeSSE(bytes) {}
            Issue.record("Expected the transport failure to propagate")
        } catch ChatRecoveryClientError.invalidResponse {
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    @Test("transient server responses remain recoverable", arguments: [500, 502, 503, 504, 599])
    func transientServerResponse(statusCode: Int) {
        #expect(shouldRetryRecoveryResponse(statusCode: statusCode))
    }

    @Test("terminal client responses do not retry", arguments: [400, 401, 404, 409, 429])
    func terminalClientResponse(statusCode: Int) {
        #expect(!shouldRetryRecoveryResponse(statusCode: statusCode))
    }

    @Test("plain gateway failures retain their retryable status")
    func plainGatewayFailure() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com/recovery/session")!,
            statusCode: 502,
            httpVersion: nil,
            headerFields: nil
        ))

        do {
            _ = try recoveryResponseNonce(from: response)
            Issue.record("Expected a plain gateway failure to fail")
        } catch {
            #expect(shouldRetryRecoveryError(error))
        }
    }

    @Test("status decodes persisted encrypted bytes")
    func statusBytes() throws {
        let status = try JSONDecoder().decode(
            ChatRecoveryStatus.self,
            from: Data(#"{"status":"processing","bytes":128}"#.utf8)
        )

        #expect(status.state == .processing)
        #expect(status.persistedBytes == 128)
    }

    @Test("status rejects invalid persisted encrypted bytes", arguments: [
        #"{"status":"complete"}"#,
        #"{"status":"complete","bytes":-1}"#,
        #"{"status":"complete","bytes":"128"}"#,
    ])
    func invalidStatusBytes(json: String) {
        do {
            _ = try JSONDecoder().decode(
                ChatRecoveryStatus.self,
                from: Data(json.utf8)
            )
            Issue.record("Expected invalid persisted bytes to fail")
        } catch {}
    }

    @Test("plain conflict is not treated as processing")
    func plainConflict() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com/recovery/session")!,
            statusCode: 409,
            httpVersion: nil,
            headerFields: nil
        ))

        do {
            _ = try recoveryResponseNonce(from: response)
            Issue.record("Expected a plain conflict to fail")
        } catch ChatRecoveryClientError.httpStatus(let statusCode) {
            #expect(statusCode == 409)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("authenticated upstream conflict preserves its nonce")
    func authenticatedConflict() throws {
        let nonceHex = String(
            repeating: "a",
            count: EHBPConstants.responseNonceLength * 2
        )
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com/recovery/session")!,
            statusCode: 409,
            httpVersion: nil,
            headerFields: [EHBPProtocol.responseNonceHeader: nonceHex]
        ))

        let nonce = try recoveryResponseNonce(from: response)

        #expect(nonce.count == EHBPConstants.responseNonceLength)
    }
}
