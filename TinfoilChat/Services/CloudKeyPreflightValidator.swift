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

enum CloudKeyValidationProbe {
    case none
    case profile
    case chat
}

struct CloudKeyValidationResult {
    let remoteState: CloudRemoteState
    let canWrite: Bool
    let probe: CloudKeyValidationProbe
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

    func validateCurrentPrimaryKey() async -> CloudKeyValidationResult {
        guard encryptionService.getKey() != nil else {
            return unknownResult(probe: .none, message: CloudKeyValidationMessages.noEncryptionKey)
        }

        guard let profileStatus = await profileSync.getSyncStatus() else {
            return unknownResult(probe: .none, message: CloudKeyValidationMessages.unknownRemoteState)
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
            return unknownResult(probe: .none, message: CloudKeyValidationMessages.unknownRemoteState)
        }

        return CloudKeyValidationResult(
            remoteState: .empty,
            canWrite: true,
            probe: .none,
            message: nil
        )
    }

    private func validateProfileProbe() async -> CloudKeyValidationResult {
        let mismatchResult = blockedResult(probe: .profile)

        let payload: String
        do {
            guard let fetchedPayload = try await profileSync.fetchEncryptedProfilePayload() else {
                return unknownResult(probe: .profile, message: CloudKeyValidationMessages.unknownProfile)
            }
            payload = fetchedPayload
        } catch {
            return unknownResult(probe: .profile, message: CloudKeyValidationMessages.unknownProfile)
        }

        do {
            guard let data = payload.data(using: .utf8) else {
                return mismatchResult
            }

            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: data)
            let result = try await encryptionService.decrypt(encrypted, as: ProfileData.self)

            guard !result.usedFallbackKey else {
                return mismatchResult
            }

            return validResult(probe: .profile)
        } catch {
            return mismatchResult
        }
    }

    private func validateChatProbe() async -> CloudKeyValidationResult {
        do {
            let response = try await cloudStorage.listChats(
                limit: Constants.Sync.keyValidationProbeCount,
                includeContent: true
            )

            guard !response.conversations.isEmpty else {
                return unknownResult(probe: .chat, message: CloudKeyValidationMessages.unknownChats)
            }

            var sawMismatch = false

            for conversation in response.conversations.prefix(Constants.Sync.keyValidationProbeCount) {
                guard let content = conversation.content else { continue }

                if conversation.formatVersion == 1 {
                    guard let binary = Data(base64Encoded: content) else {
                        sawMismatch = true
                        continue
                    }

                    do {
                        let result: DecryptionResult<Chat> = try encryptionService.decryptV1(binary, as: Chat.self)
                        if !result.usedFallbackKey {
                            return validResult(probe: .chat)
                        }
                        sawMismatch = true
                    } catch {
                        sawMismatch = true
                    }

                    continue
                }

                do {
                    let encryptedData = try JSONDecoder().decode(
                        EncryptedData.self,
                        from: Data(content.utf8)
                    )
                    let result = try await encryptionService.decrypt(encryptedData, as: Chat.self)
                    if !result.usedFallbackKey {
                        return validResult(probe: .chat)
                    }
                    sawMismatch = true
                } catch {
                    sawMismatch = true
                }
            }

            return CloudKeyValidationResult(
                remoteState: sawMismatch ? .exists : .unknown,
                canWrite: false,
                probe: .chat,
                message: sawMismatch
                    ? CloudKeyValidationMessages.keyMismatch
                    : CloudKeyValidationMessages.unknownChats
            )
        } catch {
            return unknownResult(probe: .chat, message: CloudKeyValidationMessages.unknownChats)
        }
    }

    private func unknownResult(
        probe: CloudKeyValidationProbe,
        message: String
    ) -> CloudKeyValidationResult {
        CloudKeyValidationResult(
            remoteState: .unknown,
            canWrite: false,
            probe: probe,
            message: message
        )
    }

    private func validResult(probe: CloudKeyValidationProbe) -> CloudKeyValidationResult {
        CloudKeyValidationResult(
            remoteState: .exists,
            canWrite: true,
            probe: probe,
            message: nil
        )
    }

    private func blockedResult(probe: CloudKeyValidationProbe) -> CloudKeyValidationResult {
        CloudKeyValidationResult(
            remoteState: .exists,
            canWrite: false,
            probe: probe,
            message: CloudKeyValidationMessages.keyMismatch
        )
    }
}
