import Foundation

@MainActor
final class SharedImportCoordinator {
    static let shared = SharedImportCoordinator()

    private init() {}

    func importPendingAttachments(into viewModel: ChatViewModel) {
        guard let store = try? SharedImportStore() else { return }

        let importedRequestIDs = Set(
            viewModel.pendingAttachments.compactMap(\.sharedImportRequestID)
        )
        for request in store.pendingRequests() where !importedRequestIDs.contains(request.id) {
            do {
                let data = try store.payloadData(for: request)
                switch request.item.kind {
                case .image:
                    viewModel.addImageAttachment(
                        data: data,
                        fileName: request.item.originalFileName,
                        sharedImportRequestID: request.id
                    )
                case .document:
                    viewModel.addDocumentAttachment(
                        data: data,
                        fileName: request.item.originalFileName,
                        sharedImportRequestID: request.id
                    )
                }
            } catch {
                viewModel.attachmentError = error.localizedDescription
            }
        }
    }

    func acknowledge(requestID: UUID) {
        guard let store = try? SharedImportStore() else { return }
        store.removeRequest(id: requestID)
    }

    func discardAllPending() {
        guard let store = try? SharedImportStore() else { return }
        for request in store.pendingRequests() {
            store.removeRequest(id: request.id)
        }
    }
}
