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
                let payloadURL = try store.payloadURL(for: request)
                switch request.item.kind {
                case .image:
                    let data = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
                    viewModel.addImageAttachment(
                        data: data,
                        fileName: request.item.originalFileName,
                        sharedImportRequestID: request.id
                    )
                case .document:
                    viewModel.addDocumentAttachment(
                        url: payloadURL,
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
}
