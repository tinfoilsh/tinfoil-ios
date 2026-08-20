import Foundation

@MainActor
final class SharedImportCoordinator {
    static let shared = SharedImportCoordinator()

    private enum PendingImport: @unchecked Sendable {
        case image(Data, String, UUID)
        case document(ManagedStagedFile, String, UUID)
        case failure(String)
    }

    private var importTask: Task<Void, Never>?
    private var acknowledgementTasks: [UUID: Task<Void, Never>] = [:]
    private var importsPaused = false
    private var pausedOwnerUserId: String?
    private var pausedImportsWereDiscarded = false
    private var publicationBlockEstablished = false
    private var pauseGeneration: UInt64 = 0

    private init() {}

    func importPendingAttachments(into viewModel: ChatViewModel) {
        guard !importsPaused, importTask == nil else { return }

        let importedRequestIDs = Set(
            viewModel.pendingAttachments.compactMap(\.sharedImportRequestID)
        ).union(acknowledgementTasks.keys)
        importTask = Task { [weak self, weak viewModel] in
            defer { self?.importTask = nil }
            let requestTask = Task.detached(priority: .userInitiated) {
                guard let store = try? SharedImportStore() else { return [SharedImportRequest]() }
                return store.pendingRequests()
                    .filter { !importedRequestIDs.contains($0.id) }
            }
            let requests = await withTaskCancellationHandler {
                await requestTask.value
            } onCancel: {
                requestTask.cancel()
            }
            guard !Task.isCancelled, self?.importsPaused == false else { return }
            for request in requests {
                guard !Task.isCancelled, self?.importsPaused == false else { return }
                let worker = Task.detached(priority: .userInitiated) { () -> PendingImport? in
                    do {
                        try Task.checkCancellation()
                        let store = try SharedImportStore()
                        switch request.item.kind {
                        case .image:
                            let data = try store.payloadData(for: request)
                            try Task.checkCancellation()
                            return .image(data, request.item.originalFileName, request.id)
                        case .document:
                            let file = try ManagedFileStore.shared.stage(
                                sourceURL: store.payloadURL(for: request),
                                maximumSize: request.item.kind.maximumSizeBytes
                            )
                            guard !Task.isCancelled else {
                                file.discard()
                                return nil
                            }
                            return .document(file, request.item.originalFileName, request.id)
                        }
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
                guard let pendingImport = await withTaskCancellationHandler(
                    operation: { await worker.value },
                    onCancel: { worker.cancel() }
                ) else {
                    guard !Task.isCancelled else { return }
                    continue
                }
                guard !Task.isCancelled, self?.importsPaused == false, let viewModel else {
                    if case .document(let file, _, _) = pendingImport {
                        file.discard()
                    }
                    return
                }
                switch pendingImport {
                case .image(let data, let fileName, let requestID):
                    if let processingTask = viewModel.addImageAttachment(
                        data: data,
                        fileName: fileName,
                        sharedImportRequestID: requestID
                    ) {
                        await withTaskCancellationHandler {
                            await processingTask.value
                        } onCancel: {
                            processingTask.cancel()
                        }
                    }
                case .document(let file, let fileName, let requestID):
                    if let processingTask = viewModel.addDocumentAttachment(
                        file: file,
                        fileName: fileName,
                        sharedImportRequestID: requestID
                    ) {
                        await withTaskCancellationHandler {
                            await processingTask.value
                        } onCancel: {
                            processingTask.cancel()
                        }
                    }
                case .failure(let message):
                    viewModel.attachmentError = message
                }
            }
        }
    }

    func acknowledge(requestID: UUID, onFailure: @escaping (String) -> Void) {
        guard !importsPaused, acknowledgementTasks[requestID] == nil else { return }
        let task = Task { [weak self] in
            let failureMessage = await Task.detached(priority: .utility) {
                do {
                    let store = try SharedImportStore()
                    try store.removeRequest(id: requestID)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            acknowledgementTasks.removeValue(forKey: requestID)
            if let failureMessage {
                onFailure(failureMessage)
            }
        }
        acknowledgementTasks[requestID] = task
    }

    func discardAllPending() async throws {
        pauseGeneration += 1
        importsPaused = true
        if let importTask {
            importTask.cancel()
            await importTask.value
            self.importTask = nil
        }
        let acknowledgements = Array(acknowledgementTasks.values)
        for task in acknowledgements { await task.value }
        try await Task.detached(priority: .userInitiated) {
            let store = try SharedImportStore()
            try store.purgeAllRequests()
        }.value
        pausedOwnerUserId = nil
        pausedImportsWereDiscarded = true
        publicationBlockEstablished = true
    }

    func beginPausingPreservedImports(ownerUserId: String?) {
        pauseGeneration += 1
        importsPaused = true
        pausedOwnerUserId = ownerUserId ?? pausedOwnerUserId
        pausedImportsWereDiscarded = false
        publicationBlockEstablished = false
        importTask?.cancel()
    }

    func pausePreservingPendingImports(ownerUserId: String?) async throws {
        beginPausingPreservedImports(ownerUserId: ownerUserId)
        let pausedGeneration = pauseGeneration
        let publicationBlockTask = Task.detached(priority: .utility) {
            let store = try SharedImportStore()
            try store.blockPublications()
        }
        if let importTask {
            await importTask.value
            self.importTask = nil
        }
        try await publicationBlockTask.value
        guard pauseGeneration == pausedGeneration else { throw CancellationError() }
        publicationBlockEstablished = true
        let acknowledgements = Array(acknowledgementTasks.values)
        for task in acknowledgements { await task.value }
    }

    func allowPublications(validatedOwnerUserId: String) async throws {
        guard !importsPaused
                || pausedImportsWereDiscarded
                || pausedOwnerUserId == nil
                || pausedOwnerUserId == validatedOwnerUserId else {
            throw SharedImportError.publicationBlocked
        }
        let resumeGeneration = pauseGeneration
        if importsPaused, !pausedImportsWereDiscarded, pausedOwnerUserId == nil {
            try await Task.detached(priority: .utility) {
                let store = try SharedImportStore()
                try store.purgeAllRequests()
            }.value
            guard pauseGeneration == resumeGeneration else { throw CancellationError() }
            pausedImportsWereDiscarded = true
            publicationBlockEstablished = true
        } else if importsPaused, !pausedImportsWereDiscarded, !publicationBlockEstablished {
            try await Task.detached(priority: .utility) {
                let store = try SharedImportStore()
                try store.blockPublications()
            }.value
            guard pauseGeneration == resumeGeneration else { throw CancellationError() }
            publicationBlockEstablished = true
        }
        try await Task.detached(priority: .utility) {
            let store = try SharedImportStore()
            try store.allowPublications()
        }.value
        guard pauseGeneration == resumeGeneration else {
            try await Task.detached(priority: .utility) {
                let store = try SharedImportStore()
                try store.blockPublications()
            }.value
            throw CancellationError()
        }
        pausedOwnerUserId = nil
        pausedImportsWereDiscarded = false
        publicationBlockEstablished = false
        importsPaused = false
    }
}
