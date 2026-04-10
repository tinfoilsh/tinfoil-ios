import Foundation

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
            return CloudKeyValidationResult(
                remoteState: .unknown,
                canWrite: false,
                probe: .none,
                message: "No encryption key is currently loaded."
            )
        }

        guard let profileStatus = await profileSync.getSyncStatus() else {
            return CloudKeyValidationResult(
                remoteState: .unknown,
                canWrite: false,
                probe: .none,
                message: "We couldn't verify whether encrypted cloud data already exists."
            )
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
            return CloudKeyValidationResult(
                remoteState: .unknown,
                canWrite: false,
                probe: .none,
                message: "We couldn't verify whether encrypted cloud data already exists."
            )
        }

        return CloudKeyValidationResult(
            remoteState: .empty,
            canWrite: true,
            probe: .none,
            message: nil
        )
    }

    private func validateProfileProbe() async -> CloudKeyValidationResult {
        let payload: String
        do {
            guard let fetchedPayload = try await profileSync.fetchEncryptedProfilePayload() else {
                return CloudKeyValidationResult(
                    remoteState: .unknown,
                    canWrite: false,
                    probe: .profile,
                    message: "We couldn't verify your existing cloud profile."
                )
            }
            payload = fetchedPayload
        } catch {
            return CloudKeyValidationResult(
                remoteState: .unknown,
                canWrite: false,
                probe: .profile,
                message: "We couldn't verify your existing cloud profile."
            )
        }

        do {
            guard let data = payload.data(using: .utf8) else {
                return CloudKeyValidationResult(
                    remoteState: .exists,
                    canWrite: false,
                    probe: .profile,
                    message: "This key doesn't match your existing cloud data."
                )
            }

            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: data)
            let result = try await encryptionService.decrypt(encrypted, as: ProfileData.self)

            guard !result.usedFallbackKey else {
                return CloudKeyValidationResult(
                    remoteState: .exists,
                    canWrite: false,
                    probe: .profile,
                    message: "This key doesn't match your existing cloud data."
                )
            }

            return CloudKeyValidationResult(
                remoteState: .exists,
                canWrite: true,
                probe: .profile,
                message: nil
            )
        } catch {
            return CloudKeyValidationResult(
                remoteState: .exists,
                canWrite: false,
                probe: .profile,
                message: "This key doesn't match your existing cloud data."
            )
        }
    }

    private func validateChatProbe() async -> CloudKeyValidationResult {
        do {
            let response = try await cloudStorage.listChats(
                limit: Constants.Sync.keyValidationProbeCount,
                includeContent: true
            )

            guard !response.conversations.isEmpty else {
                return CloudKeyValidationResult(
                    remoteState: .unknown,
                    canWrite: false,
                    probe: .chat,
                    message: "We couldn't verify your existing cloud chats."
                )
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
                            return CloudKeyValidationResult(
                                remoteState: .exists,
                                canWrite: true,
                                probe: .chat,
                                message: nil
                            )
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
                        return CloudKeyValidationResult(
                            remoteState: .exists,
                            canWrite: true,
                            probe: .chat,
                            message: nil
                        )
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
                    ? "This key doesn't match your existing cloud data."
                    : "We couldn't verify your existing cloud chats."
            )
        } catch {
            return CloudKeyValidationResult(
                remoteState: .unknown,
                canWrite: false,
                probe: .chat,
                message: "We couldn't verify your existing cloud chats."
            )
        }
    }
}
