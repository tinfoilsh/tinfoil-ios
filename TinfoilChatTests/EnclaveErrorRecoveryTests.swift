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

@Suite("EnclaveErrorRecovery dispatch table")
struct EnclaveErrorRecoveryTests {

    // MARK: - Coded errors

    @Test func staleKeyMapsToRefreshCurrentKeyAndRetry() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "stale", status: 409, code: "STALE_KEY")
        )
        #expect(decision.action == .refreshCurrentKeyAndRetry)
        #expect(decision.classification.kind == .retryableRefresh)
        #expect(decision.classification.code == .staleKey)
    }

    @Test func staleBlobMapsToSurfaceConflictStaleBlob() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "stale blob", status: 409, code: "STALE_BLOB")
        )
        #expect(decision.action == .surfaceConflict(reason: .staleBlob))
        #expect(decision.classification.kind == .userDecision)
    }

    @Test func syncConflictMapsToSurfaceConflictSyncConflict() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "conflict", status: 409, code: "SYNC_CONFLICT")
        )
        #expect(decision.action == .surfaceConflict(reason: .syncConflict))
        #expect(decision.classification.kind == .userDecision)
    }

    @Test func idempotencyConflictMapsToAbortIdempotencyConflict() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "dup", status: 409, code: "IDEMPOTENCY_CONFLICT")
        )
        #expect(decision.action == .abort(reason: .idempotencyConflict))
        #expect(decision.classification.kind == .terminal)
    }

    @Test func existingDataMapsToSurfaceExistingDataUnderOtherKey() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "elsewhere", status: 409, code: "EXISTING_DATA_UNDER_OTHER_KEY")
        )
        #expect(decision.action == .surfaceExistingDataUnderOtherKey)
        #expect(decision.classification.kind == .userDecision)
    }

    @Test func unknownKeyMapsToTriggerRecoveryWizard() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "unknown", status: 412, code: "UNKNOWN_KEY")
        )
        #expect(decision.action == .triggerRecoveryWizard(reason: .unknownKey))
        #expect(decision.classification.kind == .terminal)
    }

    @Test func legacyBlobMapsToMigrateLegacyAndRetry() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "legacy", status: 410, code: "LEGACY_BLOB_NOT_MIGRATED")
        )
        #expect(decision.action == .migrateLegacyAndRetry(scope: nil))
        #expect(decision.classification.kind == .retryableRefresh)
    }

    @Test func attestationFailedMapsToBlockAllSync() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "boom", status: nil, code: "ATTESTATION_FAILED")
        )
        #expect(decision.action == .blockAllSync(reason: .attestationFailed))
        #expect(decision.classification.kind == .terminal)
    }

    @Test func authMapsToRetryAuthRefresh() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "no jwt", status: 401, code: "AUTH")
        )
        #expect(decision.action == .retry(reason: .authRefresh))
        #expect(decision.classification.kind == .retryableTransient)
    }

    @Test func forbiddenMapsToAbortForbidden() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "nope", status: 403, code: "FORBIDDEN")
        )
        #expect(decision.action == .abort(reason: .forbidden))
        #expect(decision.classification.kind == .terminal)
    }

    @Test func networkMapsToRetryNetwork() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "offline", status: nil, code: "NETWORK")
        )
        #expect(decision.action == .retry(reason: .network))
        #expect(decision.classification.kind == .retryableTransient)
    }

    @Test func notFoundMapsToSurfaceNotFound() {
        let decision = EnclaveErrorRecovery.decide(
            SyncEnclaveError(message: "missing", status: 404, code: "NOT_FOUND")
        )
        #expect(decision.action == .surfaceNotFound)
        #expect(decision.classification.kind == .userDecision)
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

    @Test func attestationMessageDetectsBlockAllSync() {
        struct E: LocalizedError {
            let errorDescription: String? = "Attestation verifier failed"
        }
        let decision = EnclaveErrorRecovery.decide(E())
        #expect(decision.action == .blockAllSync(reason: .attestationFailed))
    }

    @Test func plainErrorMapsToAbortUnknown() {
        struct E: LocalizedError {
            let errorDescription: String? = "unrelated failure"
        }
        let decision = EnclaveErrorRecovery.decide(E())
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
