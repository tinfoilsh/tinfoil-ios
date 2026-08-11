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
