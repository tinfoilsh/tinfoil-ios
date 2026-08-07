@preconcurrency import EHBP
import Foundation
import Testing
@testable import TinfoilChat

@Suite("Chat recovery client")
struct ChatRecoveryClientTests {
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

    @Test("structured error body preserves its message")
    func structuredErrorBody() {
        let error = recoveryHTTPError(
            statusCode: 400,
            data: Data(#"{"error":{"message":"maximum context length exceeded"}}"#.utf8)
        )

        #expect(error.localizedDescription == "maximum context length exceeded")
    }

    @Test("trailing SSE error decodes without a final delimiter")
    func trailingSSEError() async {
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: {\"error\":{\"message\":\"input is too long\"}}".utf8))
            continuation.finish()
        }
        let stream = ChatRecoveryClient.decodeSSE(source, statusCode: 400)

        do {
            for try await _ in stream {}
            Issue.record("Expected trailing SSE error to fail")
        } catch {
            #expect(error.localizedDescription == "input is too long")
        }
    }

    @Test("successful SSE ignores trailing comments")
    func trailingSSEComment() async throws {
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data(": keep-alive".utf8))
            continuation.finish()
        }
        let stream = ChatRecoveryClient.decodeSSE(source, statusCode: 200)
        var resultCount = 0

        for try await _ in stream {
            resultCount += 1
        }

        #expect(resultCount == 0)
    }

    @Test("non-success SSE never yields a chat result")
    func failedStatusWithChatResult() async {
        let payload = #"{"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"gpt-oss-120b","choices":[{"index":0,"delta":{"content":"unexpected"},"finish_reason":null}]}"#
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: \(payload)".utf8))
            continuation.finish()
        }
        let stream = ChatRecoveryClient.decodeSSE(source, statusCode: 400)

        do {
            for try await _ in stream {}
            Issue.record("Expected failed HTTP status to reject the stream")
        } catch let error as ChatRecoveryClientError {
            #expect(error.statusCode == 400)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("non-success empty SSE still fails")
    func failedStatusWithEmptyStream() async {
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.finish()
        }
        let stream = ChatRecoveryClient.decodeSSE(source, statusCode: 500)

        do {
            for try await _ in stream {}
            Issue.record("Expected failed HTTP status to reject the stream")
        } catch let error as ChatRecoveryClientError {
            #expect(error.statusCode == 500)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("structured context errors are not connectivity failures") @MainActor
    func contextErrorClassification() {
        let error = recoveryHTTPError(
            statusCode: 400,
            data: Data(#"{"error":{"message":"context window exceeded"}}"#.utf8)
        )

        #expect(ChatViewModel.isContextOverflowError(error))
        #expect(!ChatViewModel.isConnectionError(error))
    }
}
