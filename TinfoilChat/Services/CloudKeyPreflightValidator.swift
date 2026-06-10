//
//  CloudKeyPreflightValidator.swift
//  TinfoilChat
//
//  Validates that the locally-loaded primary CEK matches the
//  user's existing cloud data by probing the enclave directly.
//  With the v2 sync architecture, validation collapses to "ask the
//  enclave to unseal a row with this CEK and check whether it
//  refuses". The enclave returns UNKNOWN_KEY when the supplied key
//  doesn't match, and plaintext otherwise.
//

import Foundation

private enum CloudKeyValidationMessages {
    static let noEncryptionKey = "No encryption key is currently loaded."
    static let unknownRemoteState = "We couldn't verify whether encrypted cloud data already exists."
    static let keyMismatch = "This key doesn't match your existing cloud data."
}

enum CloudRemoteState {
    case empty
    case exists
    case unknown
}

/// Result of probing the local key-set against existing remote rows.
/// Mirrors the webapp's `LegacyKeyProbeOutcome` so both platforms reach
/// the same verdict when deciding whether a key may be bound.
private enum LocalKeyProbeOutcome {
    case decryptable
    case undecryptable
    case noSample
    case transientFailure
}

struct CloudKeyValidationResult {
    let remoteState: CloudRemoteState
    let canWrite: Bool
    let message: String?
}

@MainActor
final class CloudKeyPreflightValidator {
    static let shared = CloudKeyPreflightValidator()
    static let mismatchMessage = CloudKeyValidationMessages.keyMismatch

    private let profileSync = ProfileSyncService.shared
    private let cloudStorage = CloudStorageService.shared
    private let encryptionService = EncryptionService.shared

    /// Every data scope the probe samples, matching the webapp's
    /// `LEGACY_KEY_PROBE_SCOPES`. Project data can exist without any
    /// profile or chat, so all four must be checked before concluding
    /// the remote is empty.
    private static let probeScopes: [SyncScope] = [.chat, .profile, .project, .projectDocument]

    private init() {}

    /// Inspect the remote state by combining a profile-sync-status
    /// check with a chat-sync-status fallback. This does NOT require
    /// the user's CEK and is safe to call before any key is loaded.
    func inspectRemoteState() async -> CloudRemoteState {
        guard let profileStatus = await profileSync.getSyncStatus() else {
            return .unknown
        }

        if profileStatus.exists {
            return .exists
        }

        do {
            let chatStatus = try await cloudStorage.getChatSyncStatus()
            return chatStatus.count > 0 ? .exists : .empty
        } catch {
            return .unknown
        }
    }

    /// Validate the currently-loaded key-set by asking the enclave to
    /// unseal a sample of real rows across every data scope. A row the
    /// keys cannot open (`UNKNOWN_KEY`) blocks binding even when other
    /// rows decrypt; a decryptable sample confirms the key; an empty
    /// sample means there is nothing to strand. Mirrors the webapp's
    /// shared decrypt probe so both platforms gate identically.
    func validateCurrentPrimaryKey() async -> CloudKeyValidationResult {
        guard encryptionService.getKey() != nil else {
            return unknownResult(message: CloudKeyValidationMessages.noEncryptionKey)
        }

        switch await probeLocalKeysAcrossScopes() {
        case .undecryptable:
            return blockedResult()
        case .transientFailure:
            return unknownResult(message: CloudKeyValidationMessages.unknownRemoteState)
        case .decryptable:
            return validResult()
        case .noSample:
            return CloudKeyValidationResult(
                remoteState: .empty,
                canWrite: true,
                message: nil
            )
        }
    }

    /// Pull a small sample from each data scope with the local key-set
    /// (primary plus migration alternatives) and classify whether those
    /// keys can unseal whatever the enclave already holds. The probe
    /// never short-circuits on the first decryptable row: a single
    /// `UNKNOWN_KEY` anywhere is enough to refuse the bind, since binding
    /// a key that cannot open existing rows would strand that data. A
    /// transient pull failure is not proof of mismatch, so it is
    /// reported separately and the caller treats it as retryable.
    private func probeLocalKeysAcrossScopes() async -> LocalKeyProbeOutcome {
        let keys = CEKEncoding.migrationKeys()
        guard !keys.isEmpty else { return .undecryptable }

        var sawDecryptable = false
        var sawUndecryptable = false

        for scope in Self.probeScopes {
            let request: EnclavePullRequest
            if scope == .profile {
                request = EnclavePullRequest(
                    scope: .profile,
                    ids: ["profile"],
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            } else {
                request = EnclavePullRequest(
                    scope: scope,
                    ids: nil,
                    all: true,
                    cursor: nil,
                    limit: Constants.Sync.keyValidationProbeCount,
                    keys: keys
                )
            }

            do {
                let response = try await SyncEnclaveAPI.pull(request)
                for item in response.items {
                    if item.ok {
                        sawDecryptable = true
                    } else if item.code == WireCodes.unknownKey {
                        sawUndecryptable = true
                    }
                }
            } catch {
                return .transientFailure
            }
        }

        if sawUndecryptable { return .undecryptable }
        if sawDecryptable { return .decryptable }
        return .noSample
    }

    private func unknownResult(message: String) -> CloudKeyValidationResult {
        CloudKeyValidationResult(
            remoteState: .unknown,
            canWrite: false,
            message: message
        )
    }

    private func validResult() -> CloudKeyValidationResult {
        CloudKeyValidationResult(
            remoteState: .exists,
            canWrite: true,
            message: nil
        )
    }

    private func blockedResult() -> CloudKeyValidationResult {
        CloudKeyValidationResult(
            remoteState: .exists,
            canWrite: false,
            message: CloudKeyValidationMessages.keyMismatch
        )
    }
}
