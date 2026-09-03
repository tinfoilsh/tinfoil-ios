import Foundation
import Testing
@testable import TinfoilChat

struct CloudConflictPullSafetyTests {
    @Test func onlyStructuredNotFoundReturnsNil() throws {
        let item = EnclavePullItem(
            id: "chat", ok: false, plaintext: nil, keyId: nil, etag: nil,
            needsRewrap: nil, projectIdSet: nil, projectId: nil,
            code: WireCodes.notFound, reason: nil
        )
        guard case nil = try CloudStorageService.decodeDownloadedChat(item) else {
            Issue.record("Expected NOT_FOUND to return nil")
            return
        }
    }

    @Test func malformedSuccessfulPullThrowsInsteadOfCreatingPlaceholder() {
        let item = EnclavePullItem(
            id: "chat", ok: true, plaintext: "not-base64", keyId: nil, etag: "9",
            needsRewrap: nil, projectIdSet: nil, projectId: nil,
            code: nil, reason: nil
        )
        #expect(throws: CloudStorageError.self) {
            try CloudStorageService.decodeDownloadedChat(item)
        }
    }

    @Test func itemFailurePreservesStructuredCode() {
        let item = EnclavePullItem(
            id: "chat", ok: false, plaintext: nil, keyId: nil, etag: nil,
            needsRewrap: nil, projectIdSet: nil, projectId: nil,
            code: WireCodes.unknownKey, reason: "server prose"
        )
        do {
            _ = try CloudStorageService.decodeDownloadedChat(item)
            Issue.record("Expected item failure")
        } catch let error as SyncEnclaveError {
            #expect(error.code == WireCodes.unknownKey)
            #expect(error.message != "server prose")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func mismatchedResponseIdentityIsRejected() {
        let item = EnclavePullItem(
            id: "other-chat", ok: false, plaintext: nil, keyId: nil, etag: nil,
            needsRewrap: nil, projectIdSet: nil, projectId: nil,
            code: WireCodes.notFound, reason: nil
        )
        #expect(throws: CloudStorageError.self) {
            try CloudStorageService.decodeDownloadedChat(item, expectedChatId: "chat")
        }
    }
}

struct CloudPullBatchSettlementTests {
    private func okItem(_ id: String, etag: String = "2") throws -> EnclavePullItem {
        let chat = StoredChat(from: Chat(id: id, title: id, modelType: pullBatchTestModel))
        let plaintext = try CloudStorageService.encodeChatPlaintext(chat)
        return EnclavePullItem(
            id: id, ok: true, plaintext: plaintext.base64EncodedString(), keyId: nil, etag: etag,
            needsRewrap: nil, projectIdSet: nil, projectId: nil, code: nil, reason: nil
        )
    }

    private func failedItem(_ id: String, code: String) -> EnclavePullItem {
        EnclavePullItem(
            id: id, ok: false, plaintext: nil, keyId: nil, etag: nil,
            needsRewrap: nil, projectIdSet: nil, projectId: nil, code: code, reason: nil
        )
    }

    @Test func settlesEachRowInRequestOrderWithoutHidingPeers() throws {
        let results = try CloudStorageService.settlePulledChats(
            requested: ["gone", "present", "locked"],
            items: [
                try okItem("present"),
                failedItem("locked", code: WireCodes.unknownKey),
                failedItem("gone", code: WireCodes.notFound),
            ]
        )

        #expect(results.map(\.id) == ["gone", "present", "locked"])
        guard case .unavailable(_, let goneCode) = results[0],
              case .ok(let present) = results[1],
              case .unavailable(_, let lockedCode) = results[2]
        else {
            Issue.record("Unexpected settlement: \(results)")
            return
        }
        #expect(goneCode == WireCodes.notFound)
        #expect(present.id == "present")
        #expect(present.syncVersion == 2)
        #expect(lockedCode == WireCodes.unknownKey)
    }

    @Test func rejectsIncompleteAndUnexpectedBatches() throws {
        #expect(throws: CloudStorageError.self) {
            try CloudStorageService.settlePulledChats(requested: ["chat-1"], items: [])
        }
        #expect(throws: CloudStorageError.self) {
            try CloudStorageService.settlePulledChats(
                requested: ["chat-1"],
                items: [try okItem("chat-1"), try okItem("chat-1")]
            )
        }
        #expect(throws: CloudStorageError.self) {
            try CloudStorageService.settlePulledChats(
                requested: ["chat-1"],
                items: [try okItem("chat-1"), try okItem("chat-2")]
            )
        }
    }

    @Test func settlesMalformedPlaintextAsUnavailableWithoutAbortingPeers() throws {
        let malformed = EnclavePullItem(
            id: "broken", ok: true, plaintext: "not-base64", keyId: nil, etag: "3",
            needsRewrap: nil, projectIdSet: nil, projectId: nil, code: nil, reason: nil
        )
        let results = try CloudStorageService.settlePulledChats(
            requested: ["broken", "fine"],
            items: [malformed, try okItem("fine")]
        )

        guard case .unavailable(let id, let code) = results[0],
              case .ok(let fine) = results[1]
        else {
            Issue.record("Unexpected settlement: \(results)")
            return
        }
        #expect(id == "broken")
        #expect(code == LocalPullItemCodes.malformedPayload)
        #expect(fine.id == "fine")
    }
}

private let pullBatchTestModel = ModelType(
    from: AppModelConfig(
        modelName: "gpt-oss-120b",
        image: "openai.png",
        name: "GPT OSS 120B",
        nameShort: "GPT OSS",
        description: "",
        details: "",
        parameters: "",
        contextWindow: "64k tokens",
        contextWindowTokens: 64_000,
        type: "chat",
        chat: true,
        paid: false,
        multimodal: false,
        toolCalling: nil,
        attributes: nil,
        reasoningConfig: nil
    )
)
