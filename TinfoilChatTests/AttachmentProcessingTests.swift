import Testing
@testable import TinfoilChat

@Suite("Attachment Processing Tests")
struct AttachmentProcessingTests {
    @Test("Only completed attachments can be sent")
    func onlyCompletedAttachmentsAreReady() {
        let completed = Attachment(
            type: .document,
            fileName: "complete.txt",
            processingState: .completed
        )
        let processing = Attachment(
            type: .image,
            fileName: "processing.jpg",
            processingState: .processing
        )
        let failed = Attachment(
            type: .document,
            fileName: "failed.pdf",
            processingState: .failed
        )

        #expect(attachmentsAreReadyToSend([completed]))
        #expect(!attachmentsAreReadyToSend([completed, processing]))
        #expect(!attachmentsAreReadyToSend([failed]))
    }
}
