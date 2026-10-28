import Foundation
import UniformTypeIdentifiers
import VisionKit

extension ChatViewModel {
    // MARK: - Attachments

    var isProcessingAttachment: Bool {
        pendingAttachments.contains { $0.processingState == .processing }
    }

    /// An upload the change of account stopped before the chat service
    /// converted the file.
    static let uploadInterrupted = HarnessError(
        code: HarnessErrorCode.connection,
        message: "The upload stopped before it finished. Remove the file and attach it again.",
        action: .retry
    )

    /// Marks the share-inbox requests behind these attachments as handled.
    /// Single funnel for every path that consumes or discards attachments,
    /// so acknowledgment behavior can't drift between them.
    func acknowledgeSharedImports(in attachments: [Attachment]) {
        for requestID in attachments.compactMap(\.sharedImportRequestID) {
            SharedImportCoordinator.shared.acknowledge(requestID: requestID)
        }
    }

    /// Reserves a pending attachment, then has the chat service convert the
    /// file into the attachment the next turn sends. A file the service
    /// refuses leaves the row failed, or is reported to the batch it came
    /// in.
    private func addAttachment(
        type: AttachmentType,
        fileName: String,
        sharedImportRequestID: UUID? = nil,
        managedFile: ManagedStagedFile? = nil,
        errorPublicationGeneration: Int? = nil,
        onProcessingFailure: (@MainActor (ManagedFileError) -> Void)? = nil,
        load: @escaping () async throws -> (data: Data, mimeType: String)
    ) {
        let startsNewErrorPublication = errorPublicationGeneration == nil
        let errorPublicationGeneration = errorPublicationGeneration ?? attachmentErrorPublicationFence.begin()
        if startsNewErrorPublication { attachmentError = nil }
        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(id: attachmentId, type: type, fileName: fileName, sharedImportRequestID: sharedImportRequestID, processingState: .processing)
        pendingAttachments.append(attachment)
        let process: @MainActor (AttachmentProcessingStore.Publication) async -> Void = { [weak self] publication in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let file = try await load()
                try Task.checkCancellation()
                guard let session else { throw Self.uploadInterrupted }
                let uploaded = try await session.upload(file.data, fileName: fileName, mimeType: file.mimeType)
                try Task.checkCancellation()
                guard publication.isCurrent else { return }
                uploadedAttachments[attachmentId] = uploaded
                attachment.mimeType = uploaded.mimeType
                attachment.thumbnailBase64 = uploaded.thumbnail
                attachment.textContent = uploaded.textContent
                attachment.description = uploaded.description
                attachment.fileSize = Int64(uploaded.size ?? file.data.count)
                attachment.processingState = .completed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                if let thumbnail = uploaded.thumbnail { pendingImageThumbnails[attachmentId] = thumbnail }
            } catch {
                // A row the user removed is gone; one whose upload the
                // account's change stopped shows as failed.
                guard publication.isCurrent else { return }
                let error = error is CancellationError ? Self.uploadInterrupted : error
                let failure = ManagedFileError(fileName: fileName, error: error)
                if let onProcessingFailure {
                    pendingAttachments.removeAll { $0.id == attachmentId }
                    pendingImageThumbnails.removeValue(forKey: attachmentId)
                    guard attachmentErrorPublicationFence.accepts(errorPublicationGeneration) else { return }
                    onProcessingFailure(failure)
                    return
                }
                attachment.processingState = .failed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                guard attachmentErrorPublicationFence.accepts(errorPublicationGeneration) else { return }
                attachmentError = error.localizedDescription
            }
        }
        if let managedFile {
            attachmentProcessingStore.start(id: attachmentId, stagedFile: managedFile, operation: process)
        } else {
            attachmentProcessingStore.start(id: attachmentId, operation: process)
        }
    }

    private static func mimeType(of handle: ManagedStagedFile) -> String {
        handle.contentTypeIdentifier.flatMap { UTType($0)?.preferredMIMEType } ?? HarnessUploads.mimeType(for: handle.fileName)
    }

    func addDocumentAttachment(
        url: URL,
        fileName: String,
        sharedImportRequestID: UUID? = nil,
        managedFile: ManagedStagedFile? = nil,
        errorPublicationGeneration: Int? = nil,
        onProcessingFailure: (@MainActor (ManagedFileError) -> Void)? = nil
    ) {
        let mimeType = managedFile.map(Self.mimeType(of:)) ?? HarnessUploads.mimeType(for: fileName)
        addAttachment(
            type: .document,
            fileName: fileName,
            sharedImportRequestID: sharedImportRequestID,
            managedFile: managedFile,
            errorPublicationGeneration: errorPublicationGeneration,
            onProcessingFailure: onProcessingFailure
        ) {
            (try Data(contentsOf: url), mimeType)
        }
    }

    func addDocumentAttachment(
        handle: ManagedStagedFile,
        errorPublicationGeneration: Int? = nil,
        onProcessingFailure: (@MainActor (ManagedFileError) -> Void)? = nil
    ) {
        addDocumentAttachment(
            url: handle.url,
            fileName: handle.fileName,
            managedFile: handle,
            errorPublicationGeneration: errorPublicationGeneration,
            onProcessingFailure: onProcessingFailure
        )
    }

    func addDocumentAttachments(_ batch: DocumentPickerBatch) {
        let errorPublicationGeneration = attachmentErrorPublicationFence.begin()
        let admission = DocumentPickerBatchAdmission.admit(batch.files, modelSupportsImages: currentModel.isMultimodal)
        var failures = batch.failures + admission.failures
        var successCount = admission.files.count
        for (handle, kind) in admission.files {
            switch kind {
            case .document:
                addDocumentAttachment(handle: handle, errorPublicationGeneration: errorPublicationGeneration)
            case .image:
                addImageAttachment(handle: handle, errorPublicationGeneration: errorPublicationGeneration) { [weak self] failure in
                    guard let self else { return }
                    successCount -= 1
                    failures.append(failure)
                    attachmentError = ManagedFileBatchErrorMessage.attachments(successCount: successCount, failures: failures)
                }
            }
        }
        attachmentError = ManagedFileBatchErrorMessage.attachments(successCount: successCount, failures: failures)
    }

    func addScannedDocument(_ scan: VNDocumentCameraScan) {
        guard canUseCurrentChatActions, scan.pageCount > 0 else { return }
        guard currentModel.isMultimodal else {
            attachmentError = DocumentPickerBatchAdmission.Error.imageModelUnsupported.localizedDescription
            return
        }
        let source = DocumentScanImageSource(scan: scan)
        let generation = attachmentErrorPublicationFence.beginBatch(count: scan.pageCount)
        attachmentError = nil
        // Reserve every attachment in page order before starting asynchronous work.
        for index in 0..<scan.pageCount {
            addAttachment(
                type: .image,
                fileName: "Scan Page \(index + 1).jpg",
                errorPublicationGeneration: generation,
                onProcessingFailure: { [weak self] failure in
                    guard let self, let failures = attachmentErrorPublicationFence.recordBatchFailure(failure, at: index, generation: generation) else { return }
                    attachmentError = ManagedFileBatchErrorMessage.attachments(failures)
                }
            ) {
                (try await source.imageData(at: index), Constants.Attachments.defaultImageMimeType)
            }
        }
    }

    func addImageAttachment(
        data: Data,
        fileName: String,
        sharedImportRequestID: UUID? = nil,
        errorPublicationGeneration: Int? = nil,
        onProcessingFailure: (@MainActor (ManagedFileError) -> Void)? = nil
    ) {
        addAttachment(
            type: .image,
            fileName: fileName,
            sharedImportRequestID: sharedImportRequestID,
            errorPublicationGeneration: errorPublicationGeneration,
            onProcessingFailure: onProcessingFailure
        ) {
            (data, HarnessUploads.mimeType(for: fileName))
        }
    }

    func addImageAttachment(
        handle: ManagedStagedFile,
        errorPublicationGeneration: Int? = nil,
        onAdmissionFailure: @escaping (ManagedFileError) -> Void = { _ in }
    ) {
        attachmentError = nil
        let mimeType = Self.mimeType(of: handle)
        addAttachment(
            type: .image,
            fileName: handle.fileName,
            managedFile: handle,
            errorPublicationGeneration: errorPublicationGeneration,
            onProcessingFailure: onAdmissionFailure
        ) {
            (try Data(contentsOf: handle.url), mimeType)
        }
    }

    func addSharedImportAttachments(_ batch: SharedImportAttachmentBatch) {
        let generation = attachmentErrorPublicationFence.beginBatch(count: batch.admissions.count)
        attachmentError = nil
        for (index, admission) in batch.admissions.enumerated() {
            let publishFailure: @MainActor (ManagedFileError) -> Void = { [weak self] failure in
                guard let self, let failures = attachmentErrorPublicationFence.recordBatchFailure(failure, at: index, generation: generation) else { return }
                attachmentError = ManagedFileBatchErrorMessage.attachments(failures)
            }
            switch admission {
            case let .image(data, fileName, requestID):
                addImageAttachment(data: data, fileName: fileName, sharedImportRequestID: requestID, errorPublicationGeneration: generation, onProcessingFailure: publishFailure)
            case let .document(file, requestID):
                addDocumentAttachment(url: file.url, fileName: file.fileName, sharedImportRequestID: requestID, managedFile: file, errorPublicationGeneration: generation, onProcessingFailure: publishFailure)
            case let .failure(failure):
                publishFailure(failure)
            }
        }
    }

    func removePendingAttachment(id: String) {
        attachmentProcessingStore.cancel(id: id)
        let removed = pendingAttachments.filter { $0.id == id }
        pendingAttachments.removeAll { $0.id == id }
        pendingImageThumbnails.removeValue(forKey: id)
        uploadedAttachments.removeValue(forKey: id)
        acknowledgeSharedImports(in: removed)
        if pendingAttachments.isEmpty { attachmentError = nil }
    }

    func clearPendingAttachments(acknowledgeSharedImports: Bool = true) {
        attachmentProcessingStore.cancelAll()
        let removed = pendingAttachments
        pendingAttachments.removeAll()
        pendingImageThumbnails.removeAll()
        uploadedAttachments.removeAll()
        attachmentError = nil
        if acknowledgeSharedImports { self.acknowledgeSharedImports(in: removed) }
    }
}
