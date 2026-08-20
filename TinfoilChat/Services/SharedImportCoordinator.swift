import Foundation

@MainActor
protocol SharedImportAttachmentReceiving: AnyObject {
    var pendingAttachments: [Attachment] { get }
    var attachmentError: String? { get set }

    func addImageAttachment(
        data: Data,
        fileName: String,
        sharedImportRequestID: UUID?
    )

    func addDocumentAttachment(
        url: URL,
        fileName: String,
        sharedImportRequestID: UUID?,
        managedFile: ManagedStagedFile?
    )
}

extension ChatViewModel: SharedImportAttachmentReceiving {}

@MainActor
final class SharedImportCoordinator {
    static let shared = SharedImportCoordinator()

    private let storeProvider: () throws -> SharedImportStore
    private let managedFileStore: ManagedFileStore

    init(
        storeProvider: @escaping () throws -> SharedImportStore = { try SharedImportStore() },
        managedFileStore: ManagedFileStore = .shared
    ) {
        self.storeProvider = storeProvider
        self.managedFileStore = managedFileStore
    }

    func importPendingAttachments(into receiver: SharedImportAttachmentReceiving) {
        guard let store = try? storeProvider() else { return }

        let importedRequestIDs = Set(
            receiver.pendingAttachments.compactMap(\.sharedImportRequestID)
        )
        for request in store.pendingRequests() where !importedRequestIDs.contains(request.id) {
            do {
                switch request.item.kind {
                case .image:
                    let data = try store.payloadData(for: request)
                    receiver.addImageAttachment(
                        data: data,
                        fileName: request.item.originalFileName,
                        sharedImportRequestID: request.id
                    )
                case .document:
                    let payloadURL = try store.payloadURL(for: request)
                    let managedFile = try managedFileStore.stage(
                        sourceURL: payloadURL,
                        fileName: request.item.originalFileName
                    )
                    receiver.addDocumentAttachment(
                        url: managedFile.url,
                        fileName: request.item.originalFileName,
                        sharedImportRequestID: request.id,
                        managedFile: managedFile
                    )
                }
            } catch {
                receiver.attachmentError = error.localizedDescription
            }
        }
    }

    func acknowledge(requestID: UUID) {
        guard let store = try? storeProvider() else { return }
        store.removeRequest(id: requestID)
    }
}
