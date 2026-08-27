//
//  DocumentPickerView.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

struct ManagedFileError: LocalizedError, Sendable {
    let fileName: String
    let message: String

    init(fileName: String, error: Error) {
        self.fileName = fileName
        message = error.localizedDescription
    }

    var errorDescription: String? { message }
}

struct DocumentPickerBatch: Sendable {
    let files: [ManagedStagedFile]
    let failures: [ManagedFileError]
}

struct DocumentPickerAllowedKinds: OptionSet, Sendable {
    let rawValue: Int

    static let documents = DocumentPickerAllowedKinds(rawValue: 1 << 0)
    static let images = DocumentPickerAllowedKinds(rawValue: 1 << 1)
}

struct DocumentPickerConfiguration: Sendable {
    let allowedKinds: DocumentPickerAllowedKinds
    let allowsMultipleSelection: Bool

    init(
        allowedKinds: DocumentPickerAllowedKinds = [.documents],
        allowsMultipleSelection: Bool = false
    ) {
        self.allowedKinds = allowedKinds
        self.allowsMultipleSelection = allowsMultipleSelection
    }

    var contentTypes: [UTType] {
        var types: [UTType] = []
        if allowedKinds.contains(.documents) {
            types += [
                .pdf,
                .plainText,
                .html,
                .commaSeparatedText,
                .json,
                .xml,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "docx") ?? .data,
                UTType(filenameExtension: "pptx") ?? .data,
                UTType(filenameExtension: "xlsx") ?? .data
            ]
        }
        if allowedKinds.contains(.images) {
            types.append(.image)
        }
        return types
    }
}

enum DocumentPickerBatchStager {
    static func stageOffMain(
        urls: [URL],
        startAccessing: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        stageFile: @escaping @Sendable (URL, String) throws -> ManagedStagedFile = {
            try ManagedFileStore.shared.stage(sourceURL: $0, fileName: $1)
        }
    ) async -> DocumentPickerBatch {
        await Task.detached(priority: .userInitiated) {
            stage(
                urls: urls,
                startAccessing: startAccessing,
                stopAccessing: stopAccessing,
                stageFile: stageFile
            )
        }.value
    }

    static func stage(
        urls: [URL],
        startAccessing: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        stageFile: @Sendable (URL, String) throws -> ManagedStagedFile = {
            try ManagedFileStore.shared.stage(sourceURL: $0, fileName: $1)
        }
    ) -> DocumentPickerBatch {
        var files: [ManagedStagedFile] = []
        var failures: [ManagedFileError] = []

        for sourceURL in urls {
            let fileName = sourceURL.lastPathComponent
            guard startAccessing(sourceURL) else {
                failures.append(ManagedFileError(fileName: fileName, error: BoundedFileIO.Error.readFailed))
                continue
            }

            do {
                let file = try stageFile(sourceURL, fileName)
                files.append(file)
            } catch {
                failures.append(ManagedFileError(fileName: fileName, error: error))
            }
            stopAccessing(sourceURL)
        }

        return DocumentPickerBatch(files: files, failures: failures)
    }
}

struct DocumentPickerView: UIViewControllerRepresentable {
    let configuration: DocumentPickerConfiguration
    var onDocumentsPicked: (DocumentPickerBatch) -> Void

    init(
        allowedKinds: DocumentPickerAllowedKinds = [.documents],
        allowsMultipleSelection: Bool = false,
        onDocumentsPicked: @escaping (DocumentPickerBatch) -> Void
    ) {
        configuration = DocumentPickerConfiguration(
            allowedKinds: allowedKinds,
            allowsMultipleSelection: allowsMultipleSelection
        )
        self.onDocumentsPicked = onDocumentsPicked
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: configuration.contentTypes)
        picker.allowsMultipleSelection = configuration.allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        uiViewController.allowsMultipleSelection = configuration.allowsMultipleSelection
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentsPicked: onDocumentsPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentsPicked: (DocumentPickerBatch) -> Void

        init(onDocumentsPicked: @escaping (DocumentPickerBatch) -> Void) {
            self.onDocumentsPicked = onDocumentsPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task {
                let batch = await DocumentPickerBatchStager.stageOffMain(urls: urls)
                onDocumentsPicked(batch)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
