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

    private init() {}

    func importPendingAttachments(into viewModel: ChatViewModel) {
        guard importTask == nil else { return }

        let importedRequestIDs = Set(
            viewModel.pendingAttachments.compactMap(\.sharedImportRequestID)
        )
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

    func acknowledge(requestID: UUID) {
        Task.detached(priority: .utility) {
            guard let store = try? SharedImportStore() else { return }
            try? store.removeRequest(id: requestID)
        }
    }

    func discardAllPending() async throws {
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
