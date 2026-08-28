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

        #expect(receiver.batches.count == 1)
        let document = try #require(receiver.documents.first)
        #expect(managedStore.owns(document.url))
        #expect(try BoundedFileIO.read(from: document.url, maximumBytes: 100) == Data("shared document".utf8))
        #expect(importStore.pendingRequests() == [request])

        coordinator.importPendingAttachments(into: receiver)
        #expect(receiver.batches.count == 1)

        coordinator.acknowledge(requestID: request.id)
        #expect(importStore.pendingRequests().isEmpty)
        #expect(document.managedFile.discard())
    }

    @Test("Admits multiple pending items as one ordered batch")
    func admitsOneOrderedBatch() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let importStore = try SharedImportStore(
            inboxURL: rootURL.appendingPathComponent("ShareInbox", isDirectory: true)
        )
        let managedStore = ManagedFileStore(
            directoryURL: rootURL.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        )
        _ = try importStore.enqueue(
            data: Data("image".utf8),
            typeIdentifier: UTType.png.identifier,
            originalFileName: "first.png"
        )
        _ = try importStore.enqueue(
            data: Data("document".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "second.txt"
        )
        let coordinator = SharedImportCoordinator(
            storeProvider: { importStore },
            managedFileStore: managedStore
        )
        let receiver = RecordingSharedImportReceiver()

        coordinator.importPendingAttachments(into: receiver)
        defer { receiver.documents.forEach { _ = $0.managedFile.discard() } }

        let batch = try #require(receiver.batches.first)
        let fileNames = batch.admissions.map { admission in
            switch admission {
            case let .image(_, fileName, _):
                return fileName
            case let .document(file, _):
                return file.fileName
            case let .failure(failure):
                return failure.fileName
            }
        }
        #expect(receiver.batches.count == 1)
        #expect(fileNames == ["first.png", "second.txt"])
    }

    @Test("Failed shared processing keeps its request eligible for retry")
    func failedProcessingCanRetry() throws {
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
            originalFileName: "retry.txt"
        )
        let coordinator = SharedImportCoordinator(
            storeProvider: { importStore },
            managedFileStore: managedStore
        )
        let receiver = RecordingSharedImportReceiver()

        coordinator.importPendingAttachments(into: receiver)
        receiver.discardFailedProcessing()
        coordinator.importPendingAttachments(into: receiver)
        defer { receiver.documents.forEach { _ = $0.managedFile.discard() } }

        #expect(receiver.batches.count == 2)
        #expect(receiver.pendingAttachments.compactMap(\.sharedImportRequestID) == [request.id])
        #expect(importStore.pendingRequests() == [request])
    }
}

@MainActor
private final class RecordingSharedImportReceiver: SharedImportAttachmentReceiving {
    struct Document {
        let url: URL
        let managedFile: ManagedStagedFile
    }

    var pendingAttachments: [Attachment] = []
    var batches: [SharedImportAttachmentBatch] = []
    var documents: [Document] = []

    func addSharedImportAttachments(_ batch: SharedImportAttachmentBatch) {
        batches.append(batch)
        for admission in batch.admissions {
            switch admission {
            case let .image(data, fileName, requestID):
                pendingAttachments.append(Attachment(
                    type: .image,
                    fileName: fileName,
                    fileSize: Int64(data.count),
                    sharedImportRequestID: requestID,
                    processingState: .completed
                ))
            case let .document(file, requestID):
                documents.append(Document(url: file.url, managedFile: file))
                pendingAttachments.append(Attachment(
                    type: .document,
                    fileName: file.fileName,
                    sharedImportRequestID: requestID,
                    processingState: .completed
                ))
            case .failure:
                break
            }
        }
    }

    func discardFailedProcessing() {
        documents.forEach { _ = $0.managedFile.discard() }
        documents = []
        pendingAttachments = []
    }
}
