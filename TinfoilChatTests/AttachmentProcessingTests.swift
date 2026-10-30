import Testing
import UIKit
@testable import TinfoilChat

private typealias Attachment = TinfoilChat.Attachment

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

    @Test("A picked image's preview is made on the device, scaled down")
    func pickedImagePreviewIsScaledDown() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        }
        let thumbnail = try #require(await ChatViewModel.previewThumbnail(of: photo))
        let image = try #require(Data(base64Encoded: thumbnail).flatMap(UIImage.init(data:)))
        #expect(image.size.width * image.scale == CGFloat(Constants.Attachments.thumbnailMaxDimension))
        #expect(image.size.height * image.scale == CGFloat(Constants.Attachments.thumbnailMaxDimension) / 2)
        #expect(await ChatViewModel.previewThumbnail(of: Data("not an image".utf8)) == nil)
    }
}
