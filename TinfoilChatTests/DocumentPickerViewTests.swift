import Foundation
import Testing
@testable import TinfoilChat

@Suite("Document Picker View Tests")
struct DocumentPickerViewTests {
    @Test("Propagates managed staging errors")
    @MainActor
    func propagatesManagedStagingErrors() async {
        let expectedSize: Int64 = 2_048
        let expectedMaximum: Int64 = 1_024
        var receivedError: Error?
        let coordinator = DocumentPickerView.Coordinator(
            onDocumentPicked: { _, _ in },
            onError: { receivedError = $0 },
            accountLifecycleGeneration: 0,
            isAccountLifecycleCurrent: { $0 == 0 },
            stageDocument: { _ in
                throw BoundedFileIOError.fileTooLarge(
                    size: expectedSize,
                    maximum: expectedMaximum
                )
            }
        )

        await coordinator.stageDocument(at: URL(fileURLWithPath: "/tmp/oversized.txt"))

        guard let error = receivedError as? BoundedFileIOError,
              case let .fileTooLarge(size, maximum) = error else {
            Issue.record("Expected an oversized managed staging error")
            return
        }
        #expect(size == expectedSize)
        #expect(maximum == expectedMaximum)
    }

    @Test("Discards staging completed after an account change")
    @MainActor
    func discardsStaleStagingResult() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("old account".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = ManagedFileStore(rootURL: rootURL.appendingPathComponent("staging"))
        var didPublishResult = false
        let coordinator = DocumentPickerView.Coordinator(
            onDocumentPicked: { _, _ in didPublishResult = true },
            onError: { _ in didPublishResult = true },
            accountLifecycleGeneration: 1,
            isAccountLifecycleCurrent: { _ in false },
            stageDocument: { url in
                try store.stage(sourceURL: url, maximumSize: 1_024)
            }
        )

        await coordinator.stageDocument(at: sourceURL)

        #expect(!didPublishResult)
        #expect((try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)).isEmpty)
    }
}
