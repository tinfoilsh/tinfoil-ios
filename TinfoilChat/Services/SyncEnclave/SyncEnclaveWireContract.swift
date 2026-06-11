//
//  SyncEnclaveWireContract.swift
//  TinfoilChat
//
//  Swift mirror of the Go wire contract defined in
//  github.com/tinfoilsh/controlplane/pkg/contract.
//
//  These strings are the public surface of the /api/sync/* and
//  enclave /v1/* HTTP APIs. Renaming any of them is a cross-repo
//  wire break. When the controlplane changes the canonical contract
//  this file must be updated in lockstep — the matching files are:
//    - controlplane/pkg/contract/headers.go
//    - controlplane/pkg/contract/sentinels.go
//    - controlplane/pkg/contract/wirecodes.go
//

import Foundation

enum SyncHeaders {
    static let idempotency = "X-Idempotency-Key"
    static let keyID = "X-Key-Id"
    static let ifMatch = "If-Match"
    static let eTag = "ETag"
    static let operationHash = "X-Operation-Hash"
    static let messageCount = "X-Message-Count"
    static let projectID = "X-Project-Id"
    static let projectIDSet = "X-Project-Id-Set"
}

enum RestoreDeletedHeaders {
    static let chat = "X-Restore-Deleted-Chat"
    static let profile = "X-Restore-Deleted-Profile"
    static let project = "X-Restore-Deleted-Project"
    static let projectDocument = "X-Restore-Deleted-Project-Document"
}

enum IfMatchSentinels {
    /// "Create only" — succeeds only if no row exists yet (blob scope).
    static let createOnly = "0"
    /// "Any key" — succeeds only if no key is registered for the user.
    static let anyKey = "*"
}

/// Wire error codes. The canonical strings live as the raw values of
/// `EnclaveErrorCode` (EnclaveErrorRecovery.swift) so the wire
/// contract and the recovery classifier can never drift apart; these
/// aliases let wire-level call sites name a code without reaching
/// into the classification enum.
enum WireCodes {
    static let preconditionRequired = EnclaveErrorCode.preconditionRequired.rawValue
    static let staleBlob = EnclaveErrorCode.staleBlob.rawValue
    static let staleKey = EnclaveErrorCode.staleKey.rawValue
    static let idempotencyConflict = EnclaveErrorCode.idempotencyConflict.rawValue
    static let existingDataUnderOtherKey = EnclaveErrorCode.existingDataUnderOtherKey.rawValue
    static let syncConflict = EnclaveErrorCode.syncConflict.rawValue
    static let notFound = EnclaveErrorCode.notFound.rawValue
    static let unknownKey = EnclaveErrorCode.unknownKey.rawValue
    static let legacyBlobNotMigrated = EnclaveErrorCode.legacyBlobNotMigrated.rawValue
    static let attestationFailed = EnclaveErrorCode.attestationFailed.rawValue
    static let auth = EnclaveErrorCode.auth.rawValue
    static let forbidden = EnclaveErrorCode.forbidden.rawValue
    static let network = EnclaveErrorCode.network.rawValue
}
