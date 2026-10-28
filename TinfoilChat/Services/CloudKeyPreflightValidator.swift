//
//  CloudKeyPreflightValidator.swift
//  TinfoilChat
//
//  Validates that the locally-loaded primary CEK is consistent with
//  what the chat service's key registry reports as the user's current
//  key. The registry owns key identity — the authoritative answer is
//  "does the local CEK derive the same key id the registry has?".
//  Legacy (un-keyed) data never blocks the local key: which rows a key
//  can unseal is only provable by decrypting, and the migration sweep
//  is self-guarding — the chat service reseals only rows it successfully
//  decrypts, leaving the rest on cooldown.
//

import Foundation

private enum CloudKeyValidationMessages {
    static let noEncryptionKey = "No encryption key is currently loaded."
    static let unknownRemoteState = "We couldn't verify whether encrypted cloud data already exists."
    static let keyMismatch = "This key doesn't match your existing cloud data."
}

struct CloudKeyValidationResult {
    let canWrite: Bool
    let message: String?
}

@MainActor
final class CloudKeyPreflightValidator {
    static let shared = CloudKeyPreflightValidator()
    static let mismatchMessage = CloudKeyValidationMessages.keyMismatch
    static let unknownRemoteStateMessage = CloudKeyValidationMessages.unknownRemoteState

    private let encryptionService = EncryptionService.shared

    private init() {}

    /// Validate the local CEK against the registry's current key id.
    ///
    ///  - No local key loaded                     → canWrite=false
    ///  - Registry unreachable                    → canWrite=false
    ///  - No remote key and no data               → canWrite=true
    ///  - Legacy data but no registered key       → canWrite=true
    ///  - Local key id matches the registry's     → canWrite=true
    ///  - Local key id differs from the registry  → canWrite=false
    ///
    /// Legacy (un-keyed) data never blocks the local key: which rows the
    /// key can actually unseal is only provable by decrypting, and the
    /// migration sweep is self-guarding — the chat service reseals only
    /// rows it successfully decrypts, leaving the rest on cooldown.
    /// Blocking on a decrypt probe produced false negatives for mixed-key
    /// v1 accounts (rows sealed under several historical keys) and silently
    /// prevented any migration at all. Mirrors the webapp's preflight.
    func validateCurrentPrimaryKey() async -> CloudKeyValidationResult {
        let cek: Data
        do {
            cek = try encryptionService.getKeyBytesOrThrow()
        } catch {
            return blockedResult(message: CloudKeyValidationMessages.noEncryptionKey)
        }

        let current: KeyState
        do {
            current = try await KeyRegistry.shared.current()
        } catch {
            return blockedResult(message: CloudKeyValidationMessages.unknownRemoteState)
        }

        guard let remoteKeyId = current.keyId else {
            return validResult()
        }

        guard let localKeyId = try? ContentKeyBundle.deriveKeyIdHex(cek: cek) else {
            return blockedResult(message: CloudKeyValidationMessages.keyMismatch)
        }

        return localKeyId == remoteKeyId
            ? validResult()
            : blockedResult(message: CloudKeyValidationMessages.keyMismatch)
    }

    private func validResult() -> CloudKeyValidationResult {
        CloudKeyValidationResult(canWrite: true, message: nil)
    }

    private func blockedResult(message: String) -> CloudKeyValidationResult {
        CloudKeyValidationResult(canWrite: false, message: message)
    }
}
