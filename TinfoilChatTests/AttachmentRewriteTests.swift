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

    @Test("rewrites matching client ids and leaves the rest untouched", arguments: [false, true])
    func rewritesMatchingAttachments(locallyModified: Bool) {
        var target = chat([image(id: "local-a"), image(id: "local-b"), image(id: "srv-c", encryptionKey: "kc")])
        target.locallyModified = locallyModified
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
        #expect(target.locallyModified == locallyModified, "sync bookkeeping is left for finalize")
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

    @Test("forgets server identity only for attachments it can re-upload")
    func forgetsOnlyReuploadable() {
        var target = chat([
            image(id: "srv-full", encryptionKey: "k-full"),
            Attachment(
                id: "srv-thumb-only",
                type: .image,
                fileName: "thumb.png",
                mimeType: "image/png",
                base64: nil,
                thumbnailBase64: "dGh1bWI=",
                fileSize: 3,
                encryptionKey: "k-thumb",
                processingState: .completed
            ),
            image(id: "srv-untouched", encryptionKey: "k-other"),
        ])

        let reset = EncryptedFileStorage.forgetServerAttachments(
            ["srv-full", "srv-thumb-only"],
            in: &target
        )

        #expect(reset == ["srv-full"])
        let byId = Dictionary(uniqueKeysWithValues: target.messages[0].attachments.map { ($0.id, $0) })
        #expect(byId["srv-full"]?.encryptionKey == nil)
        #expect(byId["srv-full"]?.base64 == "AQID")
        #expect(byId["srv-thumb-only"]?.encryptionKey == "k-thumb")
        #expect(byId["srv-untouched"]?.encryptionKey == "k-other")
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

    @Test("does not forget server keys when image bytes cannot be decoded", arguments: ["not base64!", "AQ"])
    func preservesKeysForInvalidImageBytes(base64: String) {
        var attachment = image(id: "srv-invalid", encryptionKey: "k-invalid")
        attachment.base64 = base64
        var target = chat([attachment, image(id: "srv-valid", encryptionKey: "k-valid")])

        let reset = EncryptedFileStorage.forgetServerAttachments(
            ["srv-invalid", "srv-valid"],
            in: &target
        )

        #expect(reset == ["srv-valid"])
        #expect(target.messages[0].attachments[0].encryptionKey == "k-invalid")
        #expect(target.messages[0].attachments[0].base64 == base64)
        #expect(target.messages[0].attachments[1].encryptionKey == nil)
    }

    @Test("does not claim to re-upload documents when only image uploads are supported")
    func preservesKeysForDocuments() {
        let document = Attachment(
            id: "srv-document",
            type: .document,
            fileName: "document.txt",
            mimeType: "text/plain",
            textContent: "Document text",
            encryptionKey: "k-document",
            processingState: .completed
        )
        var target = chat([document])

        let reset = EncryptedFileStorage.forgetServerAttachments([document.id], in: &target)

        #expect(reset.isEmpty)
        #expect(target.messages[0].attachments[0].encryptionKey == "k-document")
        #expect(target.messages[0].attachments[0].textContent == "Document text")
    }
}
