//
//  CloudKeyPreflightValidator.swift
//  TinfoilChat
//
//  Validates that the locally-loaded primary CEK is consistent with
//  what the enclave reports as the user's current key. The enclave
//  owns key identity — the authoritative answer is "does the local
//  CEK derive the same key id the enclave has registered?". Legacy
//  (un-keyed) data never blocks the local key: which rows a key can
//  unseal is only provable by decrypting, and the migration sweep is
//  self-guarding — the enclave rewraps only rows it successfully
//  decrypts, leaving the rest on cooldown.
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

struct CloudKeyValidationResult {
    let remoteState: CloudRemoteState
    let canWrite: Bool
    let message: String?
}

@MainActor
final class CloudKeyPreflightValidator {
    static let shared = CloudKeyPreflightValidator()
    static let mismatchMessage = CloudKeyValidationMessages.keyMismatch
    static let unknownRemoteStateMessage = CloudKeyValidationMessages.unknownRemoteState

    private let profileSync = ProfileSyncService.shared
    private let cloudStorage = CloudStorageService.shared
    private let encryptionService = EncryptionService.shared

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

    /// Validate the local CEK against the enclave's current key id.
    ///
    ///  - No local key loaded                    → unknown / canWrite=false
    ///  - Enclave unreachable                    → unknown / canWrite=false
    ///  - No remote key and no data              → empty   / canWrite=true
    ///  - Legacy data but no registered key      → exists  / canWrite=true
    ///  - Local key id matches the enclave's     → exists  / canWrite=true
    ///  - Local key id differs from the enclave  → exists  / canWrite=false
    ///
    /// Legacy (un-keyed) data never blocks the local key: which rows the
    /// key can actually unseal is only provable by decrypting, and the
    /// migration sweep is self-guarding — the enclave rewraps only rows
    /// it successfully decrypts, leaving the rest on cooldown. Blocking
    /// on a decrypt probe produced false negatives for mixed-key v1
    /// accounts (rows sealed under several historical keys) and silently
    /// prevented any migration at all. Mirrors the webapp's preflight.
    func validateCurrentPrimaryKey() async -> CloudKeyValidationResult {
        let cek: Data
        do {
            cek = try encryptionService.getKeyBytesOrThrow()
        } catch {
            return unknownResult(message: CloudKeyValidationMessages.noEncryptionKey)
        }

        let current: EnclaveKeyCurrentResponse
        do {
            current = try await SyncEnclaveAPI.keyCurrent()
        } catch {
            return unknownResult(message: CloudKeyValidationMessages.unknownRemoteState)
        }

        guard let remoteKeyId = current.keyId else {
            if current.hasData {
                return validResult()
            }
            return CloudKeyValidationResult(
                remoteState: .empty,
                canWrite: true,
                message: nil
            )
        }

        guard let localKeyId = try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek) else {
            return blockedResult()
        }

        return localKeyId == remoteKeyId ? validResult() : blockedResult()
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
