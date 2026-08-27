import Foundation

struct SharedImportAttachmentBatch {
    enum Admission {
        case image(data: Data, fileName: String, requestID: UUID)
        case document(file: ManagedStagedFile, requestID: UUID)
        case failure(ManagedFileError)
    }

    let admissions: [Admission]
}

@MainActor
protocol SharedImportAttachmentReceiving: AnyObject {
    var pendingAttachments: [Attachment] { get }
    func addSharedImportAttachments(_ batch: SharedImportAttachmentBatch)
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
        var admissions: [SharedImportAttachmentBatch.Admission] = []
        for request in store.pendingRequests() where !importedRequestIDs.contains(request.id) {
            do {
                switch request.item.kind {
                case .image:
                    let data = try store.payloadData(for: request)
                    admissions.append(.image(
                        data: data,
                        fileName: request.item.originalFileName,
                        requestID: request.id
                    ))
                case .document:
                    let payloadURL = try store.payloadURL(for: request)
                    let managedFile = try managedFileStore.stage(
                        sourceURL: payloadURL,
                        fileName: request.item.originalFileName
                    )
                    admissions.append(.document(file: managedFile, requestID: request.id))
                }
            } catch {
                admissions.append(.failure(ManagedFileError(
                    fileName: request.item.originalFileName,
                    error: error
                )))
            }
        }
        guard !admissions.isEmpty else { return }
        receiver.addSharedImportAttachments(SharedImportAttachmentBatch(admissions: admissions))
    }

    func acknowledge(requestID: UUID) {
        guard let store = try? storeProvider() else { return }
        store.removeRequest(id: requestID)
    }
}
