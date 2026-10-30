import Foundation
import Testing
@testable import TinfoilChat

private typealias Attachment = TinfoilChat.Attachment

@Suite("Pre-enclave attachment ids")
struct LegacyAttachmentReuploadTests {
    private static let legacyId = "8b9b6ffd-306c-4bbc-9a23-50723cfefed7"
    private static let enclaveId = String(repeating: "ee", count: 18)

    private struct Fetch: Equatable, Sendable {
        let id: String
        let attKey: String
    }

    private actor EnclaveRecorder {
        var puts: [Data] = []
        var fetches: [Fetch] = []
        let storedBytes: Data?

        init(storedBytes: Data? = nil) { self.storedBytes = storedBytes }

        func put(_ request: EnclaveAttachmentPutRequest) throws -> EnclaveAttachmentPutResponse {
            puts.append(try #require(Data(base64Encoded: request.plaintext)))
            return EnclaveAttachmentPutResponse(ok: true, id: LegacyAttachmentReuploadTests.enclaveId, attKey: "fresh-key")
        }

        func get(_ request: EnclaveAttachmentGetRequest) throws -> Data {
            fetches.append(Fetch(id: request.id, attKey: request.attKey))
            guard let storedBytes else {
                throw SyncEnclaveError(message: "attachment not found", status: 404, code: "NOT_FOUND")
            }
            return storedBytes
        }
    }

    private func image(id: String, base64: String? = nil, key: String) -> Attachment {
        Attachment(id: id, type: .image, fileName: "photo.png", base64: base64,
                   encryptionKey: key, processingState: .completed)
    }

    private func storedChat(_ attachment: Attachment) -> StoredChat {
        let chat = Chat(id: "chat", title: "Images", messages: [
            Message(id: "message", role: .user, content: "Look", attachments: [attachment])
        ], modelType: ChatForkTests.model)
        return StoredChat(from: chat, syncVersion: 1)
    }

    private func upload(
        _ chat: inout StoredChat,
        _ recorder: EnclaveRecorder
    ) async throws -> [CloudStorageService.AttachmentRewrite] {
        try await CloudStorageService.uploadAttachments(
            &chat, offloadDocuments: true,
            onAttachmentUploaded: { _ in },
            put: { try await recorder.put($0) },
            get: { try await recorder.get($0) }
        )
    }

    @Test func reuploadsLocalBytesOnceUnderTheEnclaveId() async throws {
        var chat = storedChat(image(id: Self.legacyId, base64: "AQID", key: "legacy-key"))
        let recorder = EnclaveRecorder()

        let rewrites = try await upload(&chat, recorder)
        let repeated = try await upload(&chat, recorder)

        #expect(rewrites.map { $0.clientId } == [Self.legacyId])
        #expect(rewrites.map { $0.serverId } == [Self.enclaveId])
        #expect(rewrites.map { $0.encryptionKey } == ["fresh-key"])
        #expect(repeated.isEmpty)
        let puts = await recorder.puts
        #expect(puts == [Data([1, 2, 3])])
        let fetches = await recorder.fetches
        #expect(fetches.isEmpty)
        #expect(chat.messages[0].attachments[0].id == Self.enclaveId)
        #expect(chat.messages[0].attachments[0].encryptionKey == "fresh-key")
    }

    @Test func readsAnImageThisDeviceDoesNotHoldFromTheEnclave() async throws {
        var chat = storedChat(image(id: Self.legacyId, key: "legacy-key"))
        let recorder = EnclaveRecorder(storedBytes: Data([7, 8, 9]))

        _ = try await upload(&chat, recorder)

        let fetches = await recorder.fetches
        #expect(fetches == [Fetch(id: Self.legacyId, attKey: "legacy-key")])
        let puts = await recorder.puts
        #expect(puts == [Data([7, 8, 9])])
        #expect(chat.messages[0].attachments[0].id == Self.enclaveId)
        #expect(chat.messages[0].attachments[0].encryptionKey == "fresh-key")
    }

    @Test func leavesEnclaveMintedAttachmentsAlone() async throws {
        var chat = storedChat(image(id: Self.enclaveId, base64: "AQID", key: "existing-key"))
        let recorder = EnclaveRecorder()

        let rewrites = try await upload(&chat, recorder)

        #expect(rewrites.isEmpty)
        let puts = await recorder.puts
        #expect(puts.isEmpty)
        let fetches = await recorder.fetches
        #expect(fetches.isEmpty)
        #expect(chat.messages[0].attachments[0].encryptionKey == "existing-key")
    }

    @Test func reportsAMissingImageAsAnUnsyncedChatRatherThanADeletedOne() async throws {
        var chat = storedChat(image(id: Self.legacyId, key: "legacy-key"))
        let recorder = EnclaveRecorder()

        var thrown: Error?
        do {
            _ = try await upload(&chat, recorder)
        } catch {
            thrown = error
        }

        let failure = try #require(thrown)
        #expect(failure as? CloudStorageError == .attachmentUnavailable)
        #expect(EnclaveErrorRecovery.decide(failure).action == .abort(reason: .unknown))
        let puts = await recorder.puts
        #expect(puts.isEmpty)
        #expect(chat.messages[0].attachments[0].id == Self.legacyId)
    }
}
