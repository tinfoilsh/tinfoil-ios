import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TinfoilChat

@MainActor
@Suite("Shared Import Coordinator Tests")
struct SharedImportCoordinatorTests {
    @Test("Stages documents while retaining their inbox request")
    func stagesDocumentAndRetainsRequest() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let importStore = try SharedImportStore(
            inboxURL: rootURL.appendingPathComponent("ShareInbox", isDirectory: true)
        )
        let managedStore = ManagedFileStore(
            directoryURL: rootURL.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        )
        let request = try importStore.enqueue(
            data: Data("shared document".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "notes.txt"
        )
        let coordinator = SharedImportCoordinator(
            storeProvider: { importStore },
            managedFileStore: managedStore
        )
        let receiver = RecordingSharedImportReceiver()

        coordinator.importPendingAttachments(into: receiver)

        #expect(receiver.documents.count == 1)
        let document = try #require(receiver.documents.first)
        #expect(managedStore.owns(document.url))
        #expect(try BoundedFileIO.read(from: document.url, maximumBytes: 100) == Data("shared document".utf8))
        #expect(importStore.pendingRequests() == [request])

        coordinator.importPendingAttachments(into: receiver)
        #expect(receiver.documents.count == 1)

        coordinator.acknowledge(requestID: request.id)
        #expect(importStore.pendingRequests().isEmpty)
        #expect(document.managedFile.discard())
    }
}

@MainActor
private final class RecordingSharedImportReceiver: SharedImportAttachmentReceiving {
    struct Document {
        let url: URL
        let managedFile: ManagedStagedFile
    }

    var pendingAttachments: [Attachment] = []
    var attachmentError: String?
    var documents: [Document] = []

    func addImageAttachment(
        data: Data,
        fileName: String,
        sharedImportRequestID: UUID?
    ) {
        pendingAttachments.append(Attachment(
            type: .image,
            fileName: fileName,
            fileSize: Int64(data.count),
            sharedImportRequestID: sharedImportRequestID,
            processingState: .completed
        ))
    }

    func addDocumentAttachment(
        url: URL,
        fileName: String,
        sharedImportRequestID: UUID?,
        managedFile: ManagedStagedFile?
    ) {
        guard let managedFile else { return }
        documents.append(Document(url: url, managedFile: managedFile))
        pendingAttachments.append(Attachment(
            type: .document,
            fileName: fileName,
            sharedImportRequestID: sharedImportRequestID,
            processingState: .completed
        ))
    }
}
