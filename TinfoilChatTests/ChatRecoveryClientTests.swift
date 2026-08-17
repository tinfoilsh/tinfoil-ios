@preconcurrency import EHBP
import Foundation
import Testing
@testable import TinfoilChat

@Suite("Chat recovery client")
struct ChatRecoveryClientTests {
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
