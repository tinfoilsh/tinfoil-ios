import Foundation
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import TinfoilChat

@Suite("Document Picker Batch Tests")
struct DocumentPickerBatchTests {
    @Test("Picker configuration supports documents, optional images, and multiple selection")
    @MainActor
    func configuresAllowedKindsAndSelection() {
        let documents = DocumentPickerConfiguration(
            allowedKinds: [.documents],
            allowsMultipleSelection: true
        )
        let documentsAndImages = DocumentPickerConfiguration(
            allowedKinds: [.documents, .images],
            allowsMultipleSelection: false
        )
        #expect(documents.contentTypes.contains(.pdf))
        #expect(!documents.contentTypes.contains(.image))
        #expect(documentsAndImages.contentTypes.contains(.image))
        #expect(documents.allowsMultipleSelection)
    }

    @Test("Selected files stage sequentially off the main thread and preserve successful order")
    func stagesOrderedPartialBatch() async throws {
        let fixture = try makeFixture(fileNames: ["first.txt", "rejected.txt", "third.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let recorder = StagingRecorder()

        let batch = await DocumentPickerBatchStager.stageOffMain(
            urls: fixture.sourceURLs,
            startAccessing: { url in
                recorder.start(url)
                return true
            },
            stopAccessing: { recorder.stop($0) },
            stageFile: { url, fileName in
                recorder.recordStage(url)
                guard fileName != "rejected.txt" else { throw TestError.rejected }
                return try fixture.store.stage(sourceURL: url, fileName: fileName)
            }
        )
        defer { batch.files.forEach { $0.discard() } }

        #expect(batch.files.map(\.fileName) == ["first.txt", "third.txt"])
        #expect(batch.failures.map(\.fileName) == ["rejected.txt"])
        #expect(recorder.stagedNames == ["first.txt", "rejected.txt", "third.txt"])
        #expect(recorder.allStagesHadAccess)
        #expect(recorder.allStagesWereOffMainThread)
        #expect(recorder.stoppedNames == ["first.txt", "rejected.txt", "third.txt"])
        #expect(batch.files.allSatisfy { fixture.store.owns($0.url) })
        #expect(batch.files.allSatisfy { !fixture.sourceURLs.contains($0.url) })
    }

    @Test("Picker cancellation does not publish a staging batch")
    @MainActor
    func cancellationDoesNotPublish() {
        var callbackCount = 0
        let coordinator = DocumentPickerView.Coordinator { _ in callbackCount += 1 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText])

        coordinator.documentPickerWasCancelled(picker)

        #expect(callbackCount == 0)
    }

    @Test("Staged type metadata takes priority with an extension fallback")
    func classifiesStagedFiles() throws {
        let fixture = try makeFixture(fileNames: ["metadata.txt", "named.jpg", "fallback.png"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let metadataImage = try fixture.store.stage(
            sourceURL: fixture.sourceURLs[0],
            fileName: "metadata.txt",
            contentTypeIdentifier: UTType.png.identifier
        )
        let metadataDocument = try fixture.store.stage(
            sourceURL: fixture.sourceURLs[1],
            fileName: "named.jpg",
            contentTypeIdentifier: UTType.pdf.identifier
        )
        let extensionImage = try fixture.store.stage(
            sourceURL: fixture.sourceURLs[2],
            fileName: "fallback.png",
            contentTypeIdentifier: UTType.data.identifier
        )
        defer { [metadataImage, metadataDocument, extensionImage].forEach { $0.discard() } }

        #expect(DocumentPickerBatchAdmission.classify(metadataImage) == .image)
        #expect(DocumentPickerBatchAdmission.classify(metadataDocument) == .document)
        #expect(DocumentPickerBatchAdmission.classify(extensionImage) == .image)
    }

    @Test("A model change rejects images, cleans them up, and preserves document order")
    func rejectsImagesAfterModelChange() throws {
        let fixture = try makeFixture(fileNames: ["first.txt", "image.png", "third.pdf"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let files = try fixture.sourceURLs.map {
            try fixture.store.stage(sourceURL: $0, fileName: $0.lastPathComponent)
        }

        let result = DocumentPickerBatchAdmission.admit(files, modelSupportsImages: false)
        defer { result.files.forEach { $0.file.discard() } }

        #expect(result.files.map { $0.file.fileName } == ["first.txt", "third.pdf"])
        #expect(result.files.map(\.kind) == [.document, .document])
        #expect(result.failures.map(\.fileName) == ["image.png"])
        #expect(!FileManager.default.fileExists(atPath: files[1].url.path))
        #expect(FileManager.default.fileExists(atPath: files[0].url.path))
        #expect(FileManager.default.fileExists(atPath: files[2].url.path))
    }

    @Test("Image admission strictly rejects invalid image bytes")
    func rejectsInvalidImageData() async throws {
        let fixture = try makeFixture(fileNames: ["invalid.png"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        await #expect(throws: ImageProcessingService.ProcessingError.invalidImageData) {
            try await ImageProcessingService.shared.processImage(at: fixture.sourceURLs[0])
        }
    }

    @Test("Files images retain the ten MiB image read bound")
    func rejectsOversizedImage() async throws {
        let fixture = try makeFixture(fileNames: [])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let oversizedURL = fixture.rootURL.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(Constants.Attachments.maxImageSizeBytes + 1))
        try handle.close()

        await #expect(throws: BoundedFileIO.Error.fileTooLarge(
            size: Constants.Attachments.maxImageSizeBytes + 1,
            maximum: Constants.Attachments.maxImageSizeBytes
        )) {
            try await ImageProcessingService.shared.processImage(at: oversizedURL)
        }
    }

    @Test("Files image processing cleans up its staged handle after rejection")
    @MainActor
    func rejectedImageProcessingCleansUpHandle() async throws {
        let fixture = try makeFixture(fileNames: ["invalid.png"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let staged = try fixture.store.stage(
            sourceURL: fixture.sourceURLs[0],
            fileName: "invalid.png"
        )
        let store = AttachmentProcessingStore()

        let task = store.start(id: "invalid-image", stagedFile: staged) { _ in
            _ = try? await ImageProcessingService.shared.processImage(at: staged.url)
        }
        await task.value

        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
    }

    @Test("Project batches continue after failures and combine the result message")
    func processesProjectBatchSequentially() async throws {
        let fixture = try makeFixture(fileNames: ["first.txt", "failed.txt", "third.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let files = try fixture.sourceURLs.map {
            try fixture.store.stage(sourceURL: $0, fileName: $0.lastPathComponent)
        }
        let recorder = ProcessingRecorder()

        let result = await ManagedFileBatchProcessor.process(files: files) { file in
            await recorder.record(file.fileName)
            guard file.fileName != "failed.txt" else { throw TestError.rejected }
            return file.fileName
        }
        let pickerFailure = ManagedFileError(fileName: "unstaged.txt", error: TestError.rejected)
        let message = ManagedFileBatchErrorMessage.projectUpload(
            successCount: result.successes.count,
            failures: [pickerFailure] + result.failures
        )

        let processedFileNames = await recorder.fileNames
        #expect(processedFileNames == ["first.txt", "failed.txt", "third.txt"])
        #expect(result.successes == ["first.txt", "third.txt"])
        #expect(result.failures.map(\.fileName) == ["failed.txt"])
        #expect(message?.contains("Uploaded 2 of 4 documents.") == true)
        #expect(message?.contains("unstaged.txt") == true)
        #expect(message?.contains("failed.txt") == true)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Cancelled processing discards rejected and remaining handles")
    func cancelledProcessingDiscardsHandles() async throws {
        let fixture = try makeFixture(fileNames: ["first.txt", "second.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let files = try fixture.sourceURLs.map {
            try fixture.store.stage(sourceURL: $0, fileName: $0.lastPathComponent)
        }

        let result: ManagedFileBatchProcessingResult<String> = await ManagedFileBatchProcessor.process(
            files: files,
            operation: { _ in throw CancellationError() }
        )

        #expect(result.wasCancelled)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    private func makeFixture(fileNames: [String]) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        let sourceURLs = try fileNames.map { fileName in
            let url = rootURL.appendingPathComponent(fileName)
            try Data(fileName.utf8).write(to: url)
            return url
        }
        let store = ManagedFileStore(
            directoryURL: rootURL.appendingPathComponent("staging", isDirectory: true)
        )
        return Fixture(rootURL: rootURL, sourceURLs: sourceURLs, store: store)
    }

    private struct Fixture: @unchecked Sendable {
        let rootURL: URL
        let sourceURLs: [URL]
        let store: ManagedFileStore
    }

    private enum TestError: Error {
        case rejected
    }
}

private final class StagingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeURLs: Set<URL> = []
    private var stages: [(name: String, hadAccess: Bool, wasOffMainThread: Bool)] = []
    private var stops: [String] = []

    var stagedNames: [String] { locked { stages.map(\.name) } }
    var stoppedNames: [String] { locked { stops } }
    var allStagesHadAccess: Bool { locked { stages.allSatisfy(\.hadAccess) } }
    var allStagesWereOffMainThread: Bool { locked { stages.allSatisfy(\.wasOffMainThread) } }

    func start(_ url: URL) {
        locked { activeURLs.insert(url) }
    }

    func recordStage(_ url: URL) {
        locked {
            stages.append((url.lastPathComponent, activeURLs.contains(url), !Thread.isMainThread))
        }
    }

    func stop(_ url: URL) {
        locked {
            activeURLs.remove(url)
            stops.append(url.lastPathComponent)
        }
    }

    @discardableResult
    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor ProcessingRecorder {
    private(set) var fileNames: [String] = []

    func record(_ fileName: String) {
        fileNames.append(fileName)
    }
}
