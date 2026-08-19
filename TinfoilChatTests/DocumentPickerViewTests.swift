import Foundation
import Testing
@testable import TinfoilChat

@Suite("Document Picker View Tests")
struct DocumentPickerViewTests {
    @Test("Propagates managed staging errors")
    @MainActor
    func propagatesManagedStagingErrors() {
        let expectedSize: Int64 = 2_048
        let expectedMaximum: Int64 = 1_024
        var receivedError: Error?
        let coordinator = DocumentPickerView.Coordinator(
            onDocumentPicked: { _, _ in },
            onError: { receivedError = $0 },
            stageDocument: { _ in
                throw BoundedFileIOError.fileTooLarge(
                    size: expectedSize,
                    maximum: expectedMaximum
                )
            }
        )

        coordinator.stageDocument(at: URL(fileURLWithPath: "/tmp/oversized.txt"))

        guard let error = receivedError as? BoundedFileIOError,
              case let .fileTooLarge(size, maximum) = error else {
            Issue.record("Expected an oversized managed staging error")
            return
        }
        #expect(size == expectedSize)
        #expect(maximum == expectedMaximum)
    }
}
