import Foundation
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

    @Test("Oversized PDFs use the document size error")
    func oversizedPDFUsesDocumentSizeError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString.lowercased()).pdf")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Constants.Attachments.maxFileSizeBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await DocumentProcessingService.shared.extractText(from: url)
            Issue.record("Expected an oversized document error")
        } catch DocumentProcessingService.ProcessingError.fileTooLarge(let size) {
            #expect(size == Constants.Attachments.maxFileSizeBytes + 1)
        } catch {
            Issue.record("Expected ProcessingError.fileTooLarge, got \(error)")
        }
    }
}
