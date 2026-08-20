//
//  DocumentPickerView.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    enum PickerError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Tinfoil could not access the selected file."
        }
    }

    var onDocumentPicked: (ManagedStagedFile, String) -> Void
    var onError: (Error) -> Void
    var accountLifecycleGeneration: @MainActor () -> Int
    var isAccountLifecycleCurrent: @MainActor (Int) -> Bool

    private static let supportedTypes: [UTType] = [
        .pdf,
        .plainText,
        .html,
        .commaSeparatedText,
        .json,
        .xml,
        .image,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "pptx") ?? .data,
        UTType(filenameExtension: "xlsx") ?? .data
    ]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.supportedTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDocumentPicked: onDocumentPicked,
            onError: onError,
            accountLifecycleGeneration: accountLifecycleGeneration,
            isAccountLifecycleCurrent: isAccountLifecycleCurrent
        )
    }

    @MainActor
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentPicked: (ManagedStagedFile, String) -> Void
        let onError: (Error) -> Void
        let accountLifecycleGeneration: @MainActor () -> Int
        let isAccountLifecycleCurrent: (Int) -> Bool
        private let stageDocument: @Sendable (URL) throws -> ManagedStagedFile

        init(
            onDocumentPicked: @escaping (ManagedStagedFile, String) -> Void,
            onError: @escaping (Error) -> Void,
            accountLifecycleGeneration: @escaping @MainActor () -> Int,
            isAccountLifecycleCurrent: @escaping (Int) -> Bool,
            stageDocument: @escaping @Sendable (URL) throws -> ManagedStagedFile = {
                try ManagedFileStore.shared.stage(
                    sourceURL: $0,
                    maximumSize: Constants.Attachments.maxFileSizeBytes
                )
            }
        ) {
            self.onDocumentPicked = onDocumentPicked
            self.onError = onError
            self.accountLifecycleGeneration = accountLifecycleGeneration
            self.isAccountLifecycleCurrent = isAccountLifecycleCurrent
            self.stageDocument = stageDocument
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let sourceURL = urls.first else { return }

            guard sourceURL.startAccessingSecurityScopedResource() else {
                onError(PickerError.accessDenied)
                return
            }
            Task {
                await stageDocument(at: sourceURL)
            }
        }

        func stageDocument(at sourceURL: URL) async {
            let fileName = sourceURL.lastPathComponent
            let stageDocument = stageDocument
            let accountLifecycleGeneration = accountLifecycleGeneration()
            let result = await Task.detached(priority: .userInitiated) {
                defer { sourceURL.stopAccessingSecurityScopedResource() }
                return Result { try stageDocument(sourceURL) }
            }.value
            guard isAccountLifecycleCurrent(accountLifecycleGeneration) else {
                if case .success(let stagedFile) = result {
                    stagedFile.discard()
                }
                return
            }
            switch result {
            case .success(let stagedFile):
                onDocumentPicked(stagedFile, fileName)
            case .failure(let error):
                onError(error)
            }
        }
    }
}
