//
//  EnclaveErrorRecoveryTests.swift
//  TinfoilChatTests
//
//  Locks down the dispatch table from SyncEnclaveError to
//  RecoveryAction. Any change to either side of the mapping must
//  show up as a failure here — if a new error code lands without
//  a corresponding row in this file, the upload path silently
//  retries it forever, which is exactly the regression these
//  tests catch.
//

import Foundation
import Testing
@testable import TinfoilChat

/// One row of the coded-error dispatch table: a wire code (with the
/// status the server pairs it with) and the decision it must map to.
struct CodedErrorExpectation: CustomTestStringConvertible {
    let code: EnclaveErrorCode
    let status: Int?
    let action: RecoveryAction
    let kind: EnclaveErrorKind
    var testDescription: String { code.rawValue }
}

let codedErrorExpectations: [CodedErrorExpectation] = [
    .init(code: .staleKey, status: 409, action: .refreshCurrentKeyAndRetry, kind: .retryableRefresh),
    .init(code: .staleBlob, status: 409, action: .surfaceConflict(reason: .staleBlob), kind: .userDecision),
    .init(code: .syncConflict, status: 409, action: .surfaceConflict(reason: .syncConflict), kind: .userDecision),
    .init(code: .idempotencyConflict, status: 409, action: .abort(reason: .idempotencyConflict), kind: .terminal),
    .init(code: .existingDataUnderOtherKey, status: 409, action: .surfaceExistingDataUnderOtherKey, kind: .userDecision),
    .init(code: .unknownKey, status: 412, action: .triggerRecoveryWizard(reason: .unknownKey), kind: .terminal),
    .init(code: .legacyBlobNotMigrated, status: 410, action: .migrateLegacyAndRetry, kind: .retryableRefresh),
    .init(code: .attestationFailed, status: nil, action: .blockAllSync(reason: .attestationFailed), kind: .terminal),
    .init(code: .auth, status: 401, action: .retry(reason: .authRefresh), kind: .retryableTransient),
    .init(code: .forbidden, status: 403, action: .abort(reason: .forbidden), kind: .terminal),
    .init(code: .network, status: nil, action: .retry(reason: .network), kind: .retryableTransient),
    .init(code: .notFound, status: 404, action: .surfaceNotFound, kind: .userDecision),
    .init(code: .preconditionRequired, status: 428, action: .abort(reason: .preconditionRequired), kind: .terminal),
]

@Suite("EnclaveErrorRecovery dispatch table")
struct EnclaveErrorRecoveryTests {

    // MARK: - Coded errors

    @Test(arguments: codedErrorExpectations)
    func codedErrorMapsToExpectedDecision(_ row: CodedErrorExpectation) {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "test", status: row.status, code: row.code.rawValue)
        )
        #expect(decision.action == row.action)
        #expect(decision.classification.kind == row.kind)
        #expect(decision.classification.code == row.code)
    }

    @Test func dispatchTableCoversEveryWireCode() {
        let covered = Set(codedErrorExpectations.map(\.code))
        #expect(covered == Set(EnclaveErrorCode.allCases))
    }

    // MARK: - HTTP status fallback

    @Test func status500FamilyIsRetryableTransient() {
        for status in [500, 502, 503, 504, 599] {
            let decision = EnclaveErrorRecovery.decide(
                SyncEnclaveError(message: "5xx", status: status, code: nil)
            )
            #expect(decision.action == .retry(reason: .transient5xx), "status \(status)")
            #expect(decision.classification.kind == .retryableTransient)
        }
    }

    @Test func status401WithoutCodeMapsToRetryAuth() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "expired token", status: 401, code: nil)
        )
        #expect(decision.action == .retry(reason: .authRefresh))
    }

    @Test func status403WithoutCodeMapsToAbortForbidden() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "forbidden", status: 403, code: nil)
        )
        #expect(decision.action == .abort(reason: .forbidden))
    }

    @Test func status404WithoutCodeMapsToSurfaceNotFound() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "missing", status: 404, code: nil)
        )
        #expect(decision.action == .surfaceNotFound)
    }

    @Test func uncodedTerminalErrorMapsToAbortUnknown() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "weird", status: 418, code: nil)
        )
        #expect(decision.action == .abort(reason: .unknown))
        #expect(decision.classification.kind == .terminal)
    }

    // MARK: - Non-SyncEnclaveError fallback

    @Test func wrappedVerificationFailureMapsToBlockAllSync() {
        // Attestation failures are tagged at the verify() call site, so
        // classification never depends on what the error text says.
        struct E: LocalizedError {
            let errorDescription: String? = "code measurement mismatch"
        }
        let wrapped = SyncEnclaveClient.wrapVerificationError(E())
        let decision = EnclaveErrorRecovery.decide(wrapped)
        #expect(decision.action == .blockAllSync(reason: .attestationFailed))
        #expect(decision.classification.code == .attestationFailed)
    }

    @Test func transientNetworkFailureDuringVerificationRetries() {
        let wrapped = SyncEnclaveClient.wrapVerificationError(URLError(.timedOut))
        let decision = EnclaveErrorRecovery.decide(wrapped)
        #expect(decision.action == .retry(reason: .network))
    }

    @Test func cancellationDuringVerificationIsNotWrapped() {
        let wrapped = SyncEnclaveClient.wrapVerificationError(CancellationError())
        #expect(wrapped is CancellationError)
    }

    @Test func rawAttestationProseDoesNotControlClassification() {
        struct E: LocalizedError {
            let errorDescription: String? = "Attestation verifier failed"
        }
        let decision = EnclaveErrorRecovery.decide(E())
        #expect(decision.action == .abort(reason: .unknown))
    }

    // MARK: - Transient network errors

    @Test func urlErrorTimedOutIsRetryableTransient() {
        let decision = EnclaveErrorRecovery.decide(URLError(.timedOut))
        #expect(decision.action == .retry(reason: .network))
        #expect(decision.classification.kind == .retryableTransient)
        #expect(decision.classification.code == .network)
    }

    @Test func urlErrorNotConnectedIsRetryableTransient() {
        let decision = EnclaveErrorRecovery.decide(URLError(.notConnectedToInternet))
        #expect(decision.action == .retry(reason: .network))
    }

    @Test func urlErrorNetworkConnectionLostIsRetryableTransient() {
        let decision = EnclaveErrorRecovery.decide(URLError(.networkConnectionLost))
        #expect(decision.action == .retry(reason: .network))
    }

    @Test func nsErrorBridgedFromURLDomainIsRetryableTransient() {
        let nsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "timed out"]
        )
        let decision = EnclaveErrorRecovery.decide(nsError)
        #expect(decision.action == .retry(reason: .network))
    }

    @Test func urlErrorBadURLIsNotConsideredTransient() {
        let decision = EnclaveErrorRecovery.decide(URLError(.badURL))
        #expect(decision.action == .abort(reason: .unknown))
    }

    @Test func urlErrorSecureConnectionFailedIsNotTransient() {
        // TLS/cert failures are almost always persistent (expired
        // cert, hostname mismatch, pinning failure). Treating them
        // as transient would burn the retry budget against a server
        // that is misconfigured.
        let decision = EnclaveErrorRecovery.decide(URLError(.secureConnectionFailed))
        #expect(decision.action == .abort(reason: .unknown))
        #expect(decision.classification.kind == .terminal)
    }

    @Test func nsErrorSecureConnectionFailedIsNotTransient() {
        let nsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSLocalizedDescriptionKey: "TLS handshake failed"]
        )
        let decision = EnclaveErrorRecovery.decide(nsError)
        #expect(decision.action == .abort(reason: .unknown))
    }

    // MARK: - Unknown codes still produce a decision

    @Test func unknownEnclaveCodeFallsBackToStatusOrTerminal() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "new code", status: 422, code: "FUTURE_CODE")
        )
        #expect(decision.classification.code == nil)
        #expect(decision.action == .abort(reason: .unknown))
    }
}
