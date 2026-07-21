//
//  EnclaveErrorRecovery.swift
//  TinfoilChat
//
//  Swift port of the webapp's
//  src/services/sync-enclave/enclave-error-classification.ts +
//  enclave-error-recovery.ts. Maps every code the sync enclave can
//  return to a single concrete `RecoveryAction` that callers
//  dispatch in their catch blocks. Callers never branch on raw
//  error codes themselves.
//
//  Adding a new code requires (a) a new case in EnclaveErrorCode,
//  (b) a new branch in `classifyEnclave`, and (c) a new branch in
//  `action(for:)` so the switch stays exhaustive.
//

import Foundation

enum EnclaveErrorKind {
    /// Network blip, 5xx, refreshable 401. Caller retries under the
    /// SAME idempotency key with the existing backoff loop.
    case retryableTransient
    /// STALE_KEY / LEGACY_BLOB_NOT_MIGRATED. Caller refreshes the
    /// canonical tuple (or runs the targeted migration) and retries
    /// as a NEW logical write.
    case retryableRefresh
    /// SYNC_CONFLICT / STALE_BLOB / EXISTING_DATA_UNDER_OTHER_KEY /
    /// NOT_FOUND. Server cannot decide; surface to the user.
    case userDecision
    /// FORBIDDEN / IDEMPOTENCY_CONFLICT / UNKNOWN_KEY /
    /// ATTESTATION_FAILED / PRECONDITION_REQUIRED / unmapped errors.
    /// Stop trying.
    case terminal
}

/// Raw values are the canonical wire strings, mirroring
/// controlplane/pkg/contract/wirecodes.go in lockstep; `WireCodes`
/// aliases them for wire-level call sites. Renaming a raw value is a
/// cross-repo wire break.
enum EnclaveErrorCode: String, CaseIterable {
    case staleKey                  = "STALE_KEY"
    case staleBlob                 = "STALE_BLOB"
    case syncConflict              = "SYNC_CONFLICT"
    case idempotencyConflict       = "IDEMPOTENCY_CONFLICT"
    case existingDataUnderOtherKey = "EXISTING_DATA_UNDER_OTHER_KEY"
    case unknownKey                = "UNKNOWN_KEY"
    case legacyBlobNotMigrated     = "LEGACY_BLOB_NOT_MIGRATED"
    case attestationFailed         = "ATTESTATION_FAILED"
    case auth                      = "AUTH"
    case forbidden                 = "FORBIDDEN"
    case network                   = "NETWORK"
    case notFound                  = "NOT_FOUND"
    case preconditionRequired      = "PRECONDITION_REQUIRED"
}

struct EnclaveErrorClassification: Equatable {
    let kind: EnclaveErrorKind
    let code: EnclaveErrorCode?
    let status: Int?
    let message: String
}

enum RecoveryAction: Equatable {
    case retry(reason: RetryReason)
    case refreshCurrentKeyAndRetry
    case migrateLegacyAndRetry
    case surfaceConflict(reason: ConflictReason)
    case surfaceExistingDataUnderOtherKey
    case surfaceNotFound
    case triggerRecoveryWizard(reason: WizardReason)
    case blockAllSync(reason: BlockReason)
    case abort(reason: AbortReason)

    enum RetryReason: String, Equatable {
        case network        = "NETWORK"
        case transient5xx   = "TRANSIENT_5XX"
        case authRefresh    = "AUTH_REFRESH"
    }
    enum ConflictReason: String, Equatable {
        case syncConflict   = "SYNC_CONFLICT"
        case staleBlob      = "STALE_BLOB"
    }
    enum WizardReason: String, Equatable {
        case unknownKey     = "UNKNOWN_KEY"
    }
    enum BlockReason: String, Equatable {
        case attestationFailed = "ATTESTATION_FAILED"
    }
    enum AbortReason: String, Equatable {
        case idempotencyConflict  = "IDEMPOTENCY_CONFLICT"
        case forbidden            = "FORBIDDEN"
        case preconditionRequired = "PRECONDITION_REQUIRED"
        case unknown              = "UNKNOWN"
    }
}

struct RecoveryDecision: Equatable {
    let action: RecoveryAction
    let classification: EnclaveErrorClassification
}

enum EnclaveErrorRecovery {
    static func isVersionConflict(_ error: SyncEnclaveError) -> Bool {
        let isUncodedPrecondition = error.status == 412
            && (error.code == nil || error.usesHTTPStatusFallbackCode)
        return error.code == WireCodes.staleBlob
            || isUncodedPrecondition
            || (error.status == 409 && error.code == WireCodes.syncConflict)
    }

    /// Decide the recovery action for any thrown value from a sync
    /// enclave call. Idempotent and pure — safe to call inside a
    /// catch block before any side effects.
    static func decide(_ error: Error) -> RecoveryDecision {
        let classification = classify(error)
        return RecoveryDecision(
            action: actionFor(classification),
            classification: classification
        )
    }

    /// Classify any error from the sync enclave path into one of
    /// the four kind buckets. Pure; never throws.
    static func classify(_ error: Error) -> EnclaveErrorClassification {
        if let enclaveErr = error as? SyncEnclaveError {
            return classifyEnclave(enclaveErr)
        }
        let message = (error as NSError).localizedDescription
        // Transient transport failures (timeouts, dropped
        // connections, DNS hiccups) routinely bubble up as raw
        // URLErrors from URLSession or the TinfoilAI SDK without a
        // SyncEnclaveError wrapper. They are retryable; falling
        // through to the terminal default would silently abort
        // every offline upload.
        if isTransientNetwork(error) {
            return EnclaveErrorClassification(
                kind: .retryableTransient,
                code: .network,
                status: nil,
                message: message
            )
        }
        return EnclaveErrorClassification(
            kind: .terminal,
            code: nil,
            status: nil,
            message: message
        )
    }

    private static func classifyEnclave(_ err: SyncEnclaveError) -> EnclaveErrorClassification {
        let code = err.code.flatMap(EnclaveErrorCode.init(rawValue:))
        let status = err.status
        let message = err.message

        if let code {
            switch code {
            case .staleKey, .legacyBlobNotMigrated:
                return EnclaveErrorClassification(kind: .retryableRefresh, code: code, status: status, message: message)
            case .syncConflict, .staleBlob, .existingDataUnderOtherKey, .notFound:
                return EnclaveErrorClassification(kind: .userDecision, code: code, status: status, message: message)
            case .idempotencyConflict, .unknownKey, .forbidden, .attestationFailed, .preconditionRequired:
                return EnclaveErrorClassification(kind: .terminal, code: code, status: status, message: message)
            case .auth, .network:
                return EnclaveErrorClassification(kind: .retryableTransient, code: code, status: status, message: message)
            }
        }

        if let status {
            if (500..<600).contains(status) {
                return EnclaveErrorClassification(kind: .retryableTransient, code: nil, status: status, message: message)
            }
            if status == 401 {
                return EnclaveErrorClassification(kind: .retryableTransient, code: .auth, status: status, message: message)
            }
            if status == 403 {
                return EnclaveErrorClassification(kind: .terminal, code: .forbidden, status: status, message: message)
            }
            if status == 404 {
                return EnclaveErrorClassification(kind: .userDecision, code: .notFound, status: status, message: message)
            }
        }
        return EnclaveErrorClassification(kind: .terminal, code: nil, status: status, message: message)
    }

    private static func actionFor(_ c: EnclaveErrorClassification) -> RecoveryAction {
        if let code = c.code {
            return action(for: code)
        }
        switch c.kind {
        case .retryableTransient:
            return .retry(reason: .transient5xx)
        case .retryableRefresh:
            // Unreachable in practice: retryableRefresh requires a
            // code. Exhaustiveness only.
            return .refreshCurrentKeyAndRetry
        case .userDecision, .terminal:
            return .abort(reason: .unknown)
        }
    }

    private static func action(for code: EnclaveErrorCode) -> RecoveryAction {
        switch code {
        case .staleKey:
            return .refreshCurrentKeyAndRetry
        case .staleBlob:
            return .surfaceConflict(reason: .staleBlob)
        case .syncConflict:
            return .surfaceConflict(reason: .syncConflict)
        case .idempotencyConflict:
            return .abort(reason: .idempotencyConflict)
        case .existingDataUnderOtherKey:
            return .surfaceExistingDataUnderOtherKey
        case .unknownKey:
            return .triggerRecoveryWizard(reason: .unknownKey)
        case .legacyBlobNotMigrated:
            return .migrateLegacyAndRetry
        case .attestationFailed:
            return .blockAllSync(reason: .attestationFailed)
        case .auth:
            return .retry(reason: .authRefresh)
        case .forbidden:
            return .abort(reason: .forbidden)
        case .network:
            return .retry(reason: .network)
        case .notFound:
            return .surfaceNotFound
        case .preconditionRequired:
            // 428: the request omitted a required If-Match. That's a
            // structural client bug, not server state — retrying the
            // same request can never heal it.
            return .abort(reason: .preconditionRequired)
        }
    }

    /// True for URLSession-level transport failures we know retry
    /// can plausibly heal. TLS/cert
    /// failures are intentionally excluded — they are almost
    /// always persistent (misconfigured server, expired cert,
    /// pinning failure) and retrying just burns the budget; they
    /// fall through to the terminal default so the recovery
    /// dispatcher surfaces them.
    static func isTransientNetwork(_ error: Error) -> Bool {
        if URLErrorClassifier.isConnectivityFailure(error) {
            return true
        }
        // Request-body stream exhaustion is retry-worthy here (the retry
        // rebuilds the body) but is not a connection loss, so it extends
        // the shared connectivity set rather than living in it.
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorRequestBodyStreamExhausted
    }
}
