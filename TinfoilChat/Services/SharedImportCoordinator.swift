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

    private init() {}

    func importPendingAttachments(into viewModel: ChatViewModel) {
        guard importTask == nil else { return }

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
            for request in requests {
                guard !Task.isCancelled else { return }
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
                guard !Task.isCancelled, let viewModel else {
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
        guard acknowledgementTasks[requestID] == nil else { return }
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
    }

    func pausePreservingPendingImports() async throws {
        try await Task.detached(priority: .utility) {
            let store = try SharedImportStore()
            try store.blockPublications()
        }.value
        if let importTask {
            importTask.cancel()
            await importTask.value
            self.importTask = nil
        }
        let acknowledgements = Array(acknowledgementTasks.values)
        for task in acknowledgements { await task.value }
    }

    func allowPublications() async throws {
        try await Task.detached(priority: .utility) {
            let store = try SharedImportStore()
            try store.allowPublications()
        }.value
    }
}
