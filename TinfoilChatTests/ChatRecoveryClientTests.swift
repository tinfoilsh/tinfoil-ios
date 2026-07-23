@preconcurrency import EHBP
import Foundation
import Testing
@testable import TinfoilChat

@Suite("Chat recovery client")
struct ChatRecoveryClientTests {
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
