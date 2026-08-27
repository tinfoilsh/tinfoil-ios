import Foundation

struct ManagedFileBatchProcessingResult<Success> {
    let successes: [Success]
    let failures: [ManagedFileError]
    let wasCancelled: Bool
}

enum ManagedFileBatchProcessor {
    static func process<Success>(
        files: [ManagedStagedFile],
        operation: (ManagedStagedFile) async throws -> Success
    ) async -> ManagedFileBatchProcessingResult<Success> {
        var successes: [Success] = []
        var failures: [ManagedFileError] = []

        for (index, file) in files.enumerated() {
            do {
                successes.append(try await operation(file))
            } catch is CancellationError {
                file.discard()
                for rejectedFile in files.dropFirst(index + 1) {
                    rejectedFile.discard()
                }
                return ManagedFileBatchProcessingResult(
                    successes: successes,
                    failures: failures,
                    wasCancelled: true
                )
            } catch {
                failures.append(ManagedFileError(fileName: file.fileName, error: error))
            }
            file.discard()
        }

        return ManagedFileBatchProcessingResult(
            successes: successes,
            failures: failures,
            wasCancelled: false
        )
    }
}

enum ManagedFileBatchErrorMessage {
    static func projectUpload(successCount: Int, failures: [ManagedFileError]) -> String? {
        guard !failures.isEmpty else { return nil }
        let totalCount = successCount + failures.count
        let headline = successCount == 0
            ? "No documents were uploaded."
            : "Uploaded \(successCount) of \(totalCount) documents."
        let details = failures.map { "\($0.fileName): \($0.message)" }
        return ([headline] + details).joined(separator: "\n")
    }

    static func attachments(_ failures: [ManagedFileError]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures
            .map { "\($0.fileName): \($0.message)" }
            .joined(separator: "\n")
    }
}
