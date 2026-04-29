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
        let mismatchResult = blockedResult()

        let payload: String
        do {
            guard let fetchedPayload = try await profileSync.fetchEncryptedProfilePayload() else {
                return unknownResult(message: CloudKeyValidationMessages.unknownProfile)
            }
            payload = fetchedPayload
        } catch {
            return unknownResult(message: CloudKeyValidationMessages.unknownProfile)
        }

        do {
            guard let data = payload.data(using: .utf8) else {
                return mismatchResult
            }

            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: data)
            // Decrypt to raw bytes only: a successful AES-GCM open with the primary
            // key proves the key matches the cloud data. Avoid decoding into a
            // typed Swift schema here — the JS web client writes blobs whose
            // schema may evolve, and a Swift decode failure must not be treated
            // as "wrong key".
            let (_, usedFallback) = try await encryptionService.decryptRawWithFallbackInfo(encrypted)

            guard !usedFallback else {
                return mismatchResult
            }

            return validResult()
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
                return unknownResult(message: CloudKeyValidationMessages.unknownChats)
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
                        // Schema-free probe: a successful raw decrypt proves the
                        // primary key works. Decoding into StoredChat here would
                        // false-positive a "key mismatch" whenever the JS web
                        // client uploads a chat blob with a slightly different
                        // shape (e.g. missing optional sync metadata fields).
                        let (_, usedFallback) = try encryptionService.decryptRawV1WithFallbackInfo(binary)
                        if !usedFallback {
                            return validResult()
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
                    let (_, usedFallback) = try await encryptionService.decryptRawWithFallbackInfo(encryptedData)
                    if !usedFallback {
                        return validResult()
                    }
                    sawMismatch = true
                } catch {
                    sawMismatch = true
                }
            }

            return CloudKeyValidationResult(
                remoteState: sawMismatch ? .exists : .unknown,
                canWrite: false,
                message: sawMismatch
                    ? CloudKeyValidationMessages.keyMismatch
                    : CloudKeyValidationMessages.unknownChats
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
