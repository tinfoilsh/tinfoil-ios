import Foundation
import Testing
@testable import TinfoilChat

@Suite("Attachment rewrites")
struct AttachmentRewriteTests {
    private func image(id: String, encryptionKey: String? = nil) -> Attachment {
        Attachment(
            id: id,
            type: .image,
            fileName: "photo.png",
            mimeType: "image/png",
            base64: "AQID",
            thumbnailBase64: nil,
            fileSize: 3,
            encryptionKey: encryptionKey,
            processingState: .completed
        )
    }

    private func chat(_ attachments: [Attachment]) -> Chat {
        Chat(
            id: "chat-1",
            title: "Attachments",
            messages: [
                Message(id: "msg-1", role: .user, content: "Images", attachments: attachments)
            ],
            modelType: ChatForkTests.model,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("rewrites matching client ids and leaves the rest untouched")
    func rewritesMatchingAttachments() {
        var target = chat([image(id: "local-a"), image(id: "local-b"), image(id: "srv-c", encryptionKey: "kc")])
        let before = target.updatedAt

        let changed = EncryptedFileStorage.applyAttachmentRewrites(
            [(clientId: "local-a", serverId: "srv-a", encryptionKey: "ka")],
            to: &target
        )

        #expect(changed)
        let atts = target.messages[0].attachments
        #expect(atts[0].id == "srv-a")
        #expect(atts[0].encryptionKey == "ka")
        #expect(atts[0].base64 == "AQID", "bytes stay local until the chat is pulled back")
        #expect(atts[1].id == "local-b")
        #expect(atts[1].encryptionKey == nil)
        #expect(atts[2].id == "srv-c")
        #expect(atts[2].encryptionKey == "kc")
        #expect(target.updatedAt == before, "recording a rewrite is not a user edit")
        #expect(target.locallyModified, "sync bookkeeping is left for finalize")
    }

    @Test("reports no change when nothing matches")
    func noMatchIsNoChange() {
        var target = chat([image(id: "local-a")])
        let changed = EncryptedFileStorage.applyAttachmentRewrites(
            [(clientId: "someone-else", serverId: "srv", encryptionKey: "k")],
            to: &target
        )
        #expect(!changed)
        #expect(target.messages[0].attachments[0].id == "local-a")
    }

    @Test("tolerates duplicate client ids from the server, first wins")
    func duplicateClientIds() {
        var target = chat([image(id: "local-a")])
        _ = EncryptedFileStorage.applyAttachmentRewrites(
            [
                (clientId: "local-a", serverId: "srv-first", encryptionKey: "k1"),
                (clientId: "local-a", serverId: "srv-second", encryptionKey: "k2"),
            ],
            to: &target
        )
        #expect(target.messages[0].attachments[0].id == "srv-first")
        #expect(target.messages[0].attachments[0].encryptionKey == "k1")
    }
}
