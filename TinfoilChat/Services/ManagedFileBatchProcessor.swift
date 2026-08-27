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
            if Task.isCancelled {
                for rejectedFile in files.dropFirst(index) {
                    rejectedFile.discard()
                }
                return ManagedFileBatchProcessingResult(
                    successes: successes,
                    failures: failures,
                    wasCancelled: true
                )
            }
            do {
                let success = try await operation(file)
                successes.append(success)
                if Task.isCancelled {
                    file.discard()
                    for rejectedFile in files.dropFirst(index + 1) {
                        rejectedFile.discard()
                    }
                    return ManagedFileBatchProcessingResult(
                        successes: successes,
                        failures: failures,
                        wasCancelled: true
                    )
                }
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
            } catch where Task.isCancelled {
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

    static func attachments(successCount: Int, failures: [ManagedFileError]) -> String? {
        guard !failures.isEmpty else { return nil }
        let totalCount = successCount + failures.count
        let headline = successCount == 0
            ? "No attachments were added."
            : "Added \(successCount) of \(totalCount) attachments."
        let details = failures.map { "\($0.fileName): \($0.message)" }
        return ([headline] + details).joined(separator: "\n")
    }
}
