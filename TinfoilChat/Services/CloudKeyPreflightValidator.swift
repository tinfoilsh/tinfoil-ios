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
    static let unknownProfile = "We couldn't verify your existing cloud profile."
    static let unknownChats = "We couldn't verify your existing cloud chats."
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

    /// Validate the currently-loaded primary CEK by trying to unseal
    /// a real row with the enclave. A successful pull = the key matches;
    /// `UNKNOWN_KEY` = it does not.
    func validateCurrentPrimaryKey() async -> CloudKeyValidationResult {
        guard encryptionService.getKey() != nil else {
            return unknownResult(message: CloudKeyValidationMessages.noEncryptionKey)
        }

        guard let profileStatus = await profileSync.getSyncStatus() else {
            return unknownResult(message: CloudKeyValidationMessages.unknownRemoteState)
        }

        if profileStatus.exists {
            return await validateProfileProbe()
        }

        do {
            let chatStatus = try await cloudStorage.getChatSyncStatus()
            if chatStatus.count > 0 {
                return await validateChatProbe()
            }
        } catch {
            return unknownResult(message: CloudKeyValidationMessages.unknownRemoteState)
        }

        return CloudKeyValidationResult(
            remoteState: .empty,
            canWrite: true,
            message: nil
        )
    }

    private func validateProfileProbe() async -> CloudKeyValidationResult {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else {
            return unknownResult(message: CloudKeyValidationMessages.noEncryptionKey)
        }
        do {
            let response = try await SyncEnclaveAPI.pull(
                EnclavePullRequest(
                    scope: .profile,
                    ids: ["profile"],
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            )
            guard let item = response.items.first else {
                return unknownResult(message: CloudKeyValidationMessages.unknownProfile)
            }
            if item.ok {
                return validResult()
            }
            if item.code == WireCodes.unknownKey {
                return blockedResult()
            }
            if item.code == WireCodes.notFound {
                return unknownResult(message: CloudKeyValidationMessages.unknownProfile)
            }
            return unknownResult(message: CloudKeyValidationMessages.unknownProfile)
        } catch {
            return unknownResult(message: CloudKeyValidationMessages.unknownProfile)
        }
    }

    private func validateChatProbe() async -> CloudKeyValidationResult {
        do {
            let response = try await cloudStorage.listChats(
                limit: Constants.Sync.keyValidationProbeCount,
                includeContent: true
            )

            guard !response.conversations.isEmpty else {
                return unknownResult(message: CloudKeyValidationMessages.unknownChats)
            }

            // If any conversation has content (the enclave already
            // unsealed it with the supplied CEK), the key matches.
            // A blanket no-content response means the enclave declined
            // every row — that's UNKNOWN_KEY or NOT_FOUND territory.
            for conversation in response.conversations.prefix(Constants.Sync.keyValidationProbeCount) {
                if conversation.content != nil {
                    return validResult()
                }
            }
            return CloudKeyValidationResult(
                remoteState: .exists,
                canWrite: false,
                message: CloudKeyValidationMessages.keyMismatch
            )
        } catch {
            return unknownResult(message: CloudKeyValidationMessages.unknownChats)
        }
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
