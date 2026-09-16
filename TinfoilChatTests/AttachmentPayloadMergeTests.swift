import Foundation
import Testing
@testable import TinfoilChat

@Suite("Attachment payload merge")
struct AttachmentPayloadMergeTests {
    private let fullBase64 = String(repeating: "FULL", count: 64)

    private func image(
        id: String,
        fileName: String = "photo.png",
        fileSize: Int64 = 1234,
        base64: String? = nil,
        encryptionKey: String? = "key"
    ) -> Attachment {
        Attachment(
            id: id,
            type: .image,
            fileName: fileName,
            mimeType: "image/png",
            base64: base64,
            thumbnailBase64: "thumb",
            fileSize: fileSize,
            encryptionKey: encryptionKey,
            processingState: .completed
        )
    }

    private func userMessage(_ attachments: [Attachment]) -> Message {
        Message(role: .user, content: "What is in this image?", attachments: attachments)
    }

    @Test func copiesLocalBytesIntoWireCopyMatchedById() {
        let local = [userMessage([image(id: "att-1", base64: fullBase64)])]
        let remote = [userMessage([image(id: "att-1")])]

        let merged = AttachmentPayloadMerge.inheritingImageBytes(into: remote, from: local)

        #expect(merged[0].attachments[0].base64 == fullBase64)
        #expect(merged[0].attachments[0].thumbnailBase64 == "thumb")
    }

    @Test func matchesByMetadataWhenUploadMintedANewId() {
        let local = [userMessage([image(id: "client-id", base64: fullBase64, encryptionKey: nil)])]
        let remote = [userMessage([image(id: "server-id")])]

        let merged = AttachmentPayloadMerge.inheritingImageBytes(into: remote, from: local)

        #expect(merged[0].attachments[0].id == "server-id")
        #expect(merged[0].attachments[0].base64 == fullBase64)
    }

    @Test func doesNotLendBytesToADifferentImage() {
        let local = [userMessage([image(id: "att-1", base64: fullBase64)])]
        let remote = [userMessage([image(id: "att-2", fileName: "other.png", fileSize: 99)])]

        let merged = AttachmentPayloadMerge.inheritingImageBytes(into: remote, from: local)

        #expect(merged[0].attachments[0].base64 == nil)
    }

    @Test func leavesAmbiguousMetadataMatchesUntouched() {
        let local = [
            userMessage([
                image(id: "a", base64: "AAAA", encryptionKey: nil),
                image(id: "b", base64: "BBBB", encryptionKey: nil),
            ])
        ]
        let remote = [userMessage([image(id: "server-a")])]

        let merged = AttachmentPayloadMerge.inheritingImageBytes(into: remote, from: local)

        #expect(merged[0].attachments[0].base64 == nil)
    }

    @Test func keepsIncomingBytesWhenAlreadyPresent() {
        let local = [userMessage([image(id: "att-1", base64: "OLD")])]
        let remote = [userMessage([image(id: "att-1", base64: "NEW")])]

        let merged = AttachmentPayloadMerge.inheritingImageBytes(into: remote, from: local)

        #expect(merged[0].attachments[0].base64 == "NEW")
    }
}
