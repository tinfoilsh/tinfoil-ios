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

enum WireCodes {
    static let preconditionRequired = "PRECONDITION_REQUIRED"
    static let staleBlob = "STALE_BLOB"
    static let staleKey = "STALE_KEY"
    static let idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    static let existingDataUnderOtherKey = "EXISTING_DATA_UNDER_OTHER_KEY"
    static let syncConflict = "SYNC_CONFLICT"
    static let notFound = "NOT_FOUND"
    static let unknownKey = "UNKNOWN_KEY"
    static let legacyBlobNotMigrated = "LEGACY_BLOB_NOT_MIGRATED"
    static let attestationFailed = "ATTESTATION_FAILED"
    static let auth = "AUTH"
    static let forbidden = "FORBIDDEN"
    static let network = "NETWORK"
}
