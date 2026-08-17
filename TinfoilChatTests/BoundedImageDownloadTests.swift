import Foundation
import Testing
@testable import TinfoilChat

private enum ImageDownloadTestError: Error {
    case failed
}

private actor ImageDownloadGate {
    struct Snapshot: Sendable {
        let started: [String]
        let activeIds: [String]
        let maximumActive: Int
    }

    private var started: [String] = []
    private var activeIds: [String] = []
    private var maximumActive = 0
    private var continuations: [String: CheckedContinuation<String, Error>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func download(_ request: CloudStorageService.ImageDownloadRequest) async throws -> String {
        let attachmentId = request.attachmentId
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                started.append(attachmentId)
                activeIds.append(attachmentId)
                maximumActive = max(maximumActive, activeIds.count)
                continuations[attachmentId] = continuation
                let readyWaiters = startWaiters.filter { started.count >= $0.0 }
                startWaiters.removeAll { started.count >= $0.0 }
                readyWaiters.forEach { $0.1.resume() }
            }
        } onCancel: {
            Task { await self.cancel(attachmentId) }
        }
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func succeed(_ attachmentId: String) {
        activeIds.removeAll { $0 == attachmentId }
        continuations.removeValue(forKey: attachmentId)?.resume(returning: "base64-\(attachmentId)")
    }

    func fail(_ attachmentId: String) {
        activeIds.removeAll { $0 == attachmentId }
        continuations.removeValue(forKey: attachmentId)?.resume(throwing: ImageDownloadTestError.failed)
    }

    func snapshot() -> Snapshot {
        Snapshot(started: started, activeIds: activeIds, maximumActive: maximumActive)
    }

    private func cancel(_ attachmentId: String) {
        activeIds.removeAll { $0 == attachmentId }
        continuations.removeValue(forKey: attachmentId)?.resume(throwing: CancellationError())
    }
}

struct BoundedImageDownloadTests {
    @Test
    func imageDownloadsAreBoundedAndKeepSuccessfulIdMapping() async throws {
        #expect(Constants.Attachments.maxConcurrentImageDownloads == 3)
        let gate = ImageDownloadGate()
        let requests = makeRequests(count: 5)
        let task = Task {
            try await CloudStorageService.downloadImages(
                requests,
                maxConcurrent: Constants.Attachments.maxConcurrentImageDownloads,
                download: { try await gate.download($0) }
            )
        }

        await gate.waitForStarts(3)
        var snapshot = await gate.snapshot()
        #expect(snapshot.started.count == 3)
        #expect(snapshot.maximumActive == 3)

        let failedId = snapshot.started[0]
        await gate.fail(failedId)
        await gate.waitForStarts(4)
        snapshot = await gate.snapshot()
        await gate.succeed(snapshot.activeIds[0])
        await gate.waitForStarts(5)
        snapshot = await gate.snapshot()
        for attachmentId in snapshot.activeIds {
            await gate.succeed(attachmentId)
        }

        let result = try await task.value
        #expect(result.count == 4)
        #expect(result[failedId] == nil)
        for request in requests where request.attachmentId != failedId {
            #expect(result[request.attachmentId] == "base64-\(request.attachmentId)")
        }
        snapshot = await gate.snapshot()
        #expect(snapshot.maximumActive == Constants.Attachments.maxConcurrentImageDownloads)
    }

    @Test
    func cancellingImageDownloadsDoesNotStartReplacementWork() async {
        let gate = ImageDownloadGate()
        let requests = makeRequests(count: 5)
        let task = Task {
            try await CloudStorageService.downloadImages(
                requests,
                maxConcurrent: Constants.Attachments.maxConcurrentImageDownloads,
                download: { try await gate.download($0) }
            )
        }

        await gate.waitForStarts(3)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected image download cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let snapshot = await gate.snapshot()
        #expect(snapshot.started.count == Constants.Attachments.maxConcurrentImageDownloads)
        #expect(snapshot.activeIds.isEmpty)
    }

    private func makeRequests(count: Int) -> [CloudStorageService.ImageDownloadRequest] {
        (0..<count).map {
            CloudStorageService.ImageDownloadRequest(
                attachmentId: "attachment-\($0)",
                encryptionKey: "key-\($0)"
            )
        }
    }
}
