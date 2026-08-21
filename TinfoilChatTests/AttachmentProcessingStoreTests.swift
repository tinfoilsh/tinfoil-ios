import Foundation
import Testing
@testable import TinfoilChat

@MainActor
@Suite("Attachment Processing Store Tests")
struct AttachmentProcessingStoreTests {
    @Test("Removal cancels processing and prevents late publication")
    func removalPreventsLatePublication() async {
        let store = AttachmentProcessingStore()
        var observedCancellation = false
        var didPublish = false

        store.start(id: "document") { publication in
            await Task.yield()
            observedCancellation = Task.isCancelled
            if publication.isCurrent {
                didPublish = true
            }
        }
        let task = store.cancel(id: "document")
        await task?.value

        #expect(observedCancellation)
        #expect(!didPublish)
    }

    @Test("Clear cancels every operation and prevents late publication")
    func clearPreventsLatePublication() async {
        let store = AttachmentProcessingStore()
        var publishedIDs: [String] = []

        for id in ["document", "image"] {
            store.start(id: id) { publication in
                await Task.yield()
                if publication.isCurrent {
                    publishedIDs.append(id)
                }
            }
        }
        let tasks = store.cancelAll()
        for task in tasks {
            await task.value
        }

        #expect(tasks.count == 2)
        #expect(publishedIDs.isEmpty)
    }

    @Test("Active operations can publish once processing completes")
    func activeOperationPublishes() async {
        let store = AttachmentProcessingStore()
        var didPublish = false

        store.start(id: "document") { publication in
            if publication.isCurrent {
                didPublish = true
            }
        }
        await Task.yield()

        #expect(didPublish)
    }

    @Test("Staged files are discarded after successful and failed operations")
    func completedOperationsDiscardStagedFiles() async throws {
        let fixture = try makeStagedFile(content: "document", fileName: "success.txt")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let failedFixture = try makeStagedFile(content: "", fileName: "failure.txt")
        defer { try? FileManager.default.removeItem(at: failedFixture.rootURL) }
        let store = AttachmentProcessingStore()

        let successTask = store.start(id: "success", stagedFile: fixture.file) { _ in
            _ = try? await DocumentProcessingService.shared.extractText(from: fixture.file.url)
        }
        let failureTask = store.start(id: "failure", stagedFile: failedFixture.file) { _ in
            _ = try? await DocumentProcessingService.shared.extractText(from: failedFixture.file.url)
        }
        await successTask.value
        await failureTask.value

        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.path))
        #expect(!FileManager.default.fileExists(atPath: failedFixture.file.url.path))
    }

    @Test("Cancellation waits for extraction before discarding its staged file")
    func cancellationWaitsBeforeDiscard() async throws {
        let fixture = try makeStagedFile(content: "document", fileName: "cancel.txt")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let store = AttachmentProcessingStore()
        var extractionObservedFile = false

        let task = store.start(id: "cancel", stagedFile: fixture.file) { _ in
            let extractionTask = Task.detached {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return FileManager.default.fileExists(atPath: fixture.file.url.path)
            }
            extractionObservedFile = await withTaskCancellationHandler {
                await extractionTask.value
            } onCancel: {
                extractionTask.cancel()
            }
        }
        await Task.yield()
        store.cancel(id: "cancel")
        await task.value

        #expect(extractionObservedFile)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.path))
    }

    private func makeStagedFile(
        content: String,
        fileName: String
    ) throws -> (file: ManagedStagedFile, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        let sourceURL = rootURL.appendingPathComponent(fileName)
        try Data(content.utf8).write(to: sourceURL)
        let store = ManagedFileStore(
            directoryURL: rootURL.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        )
        return (try store.stage(sourceURL: sourceURL, fileName: fileName), rootURL)
    }
}
