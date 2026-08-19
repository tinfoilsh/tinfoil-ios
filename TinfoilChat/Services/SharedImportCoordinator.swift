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
    private var acknowledgementTokens: [UUID: UUID] = [:]

    private init() {}

    func importPendingAttachments(into viewModel: ChatViewModel) {
        guard importTask == nil else { return }

        let importedRequestIDs = Set(
            viewModel.pendingAttachments.compactMap(\.sharedImportRequestID)
        ).union(acknowledgementTasks.keys)
        importTask = Task { [weak self, weak viewModel] in
            let imports = await Task.detached(priority: .userInitiated) {
                guard let store = try? SharedImportStore() else { return [PendingImport]() }
                return store.pendingRequests()
                    .filter { !importedRequestIDs.contains($0.id) }
                    .map { request in
                        do {
                            switch request.item.kind {
                            case .image:
                                return .image(
                                    try store.payloadData(for: request),
                                    request.item.originalFileName,
                                    request.id
                                )
                            case .document:
                                let file = try ManagedFileStore.shared.stage(
                                    sourceURL: store.payloadURL(for: request),
                                    maximumSize: request.item.kind.maximumSizeBytes
                                )
                                return .document(file, request.item.originalFileName, request.id)
                            }
                        } catch {
                            return .failure(error.localizedDescription)
                        }
                    }
            }.value

            defer { self?.importTask = nil }
            guard !Task.isCancelled else {
                for case .document(let file, _, _) in imports {
                    file.discard()
                }
                return
            }
            guard let viewModel else {
                for case .document(let file, _, _) in imports {
                    file.discard()
                }
                return
            }
            for pendingImport in imports {
                switch pendingImport {
                case .image(let data, let fileName, let requestID):
                    viewModel.addImageAttachment(
                        data: data,
                        fileName: fileName,
                        sharedImportRequestID: requestID
                    )
                case .document(let file, let fileName, let requestID):
                    viewModel.addDocumentAttachment(
                        file: file,
                        fileName: fileName,
                        sharedImportRequestID: requestID
                    )
                case .failure(let message):
                    viewModel.attachmentError = message
                }
            }
        }
    }

    func acknowledge(requestID: UUID, onFailure: @escaping (String) -> Void) {
        guard acknowledgementTasks[requestID] == nil else { return }
        let token = UUID()
        acknowledgementTokens[requestID] = token
        let task = Task { [weak self] in
            let failureMessage = await Task.detached(priority: .utility) {
                do {
                    let store = try SharedImportStore()
                    do {
                        try store.removeRequest(id: requestID)
                    } catch {
                        try store.removeRequest(id: requestID)
                    }
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self, acknowledgementTokens[requestID] == token else { return }
            acknowledgementTokens.removeValue(forKey: requestID)
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

    func allowPublications() async throws {
        try await Task.detached(priority: .utility) {
            let store = try SharedImportStore()
            try store.allowPublications()
        }.value
    }
}
