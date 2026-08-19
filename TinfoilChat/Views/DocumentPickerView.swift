//
//  DocumentPickerView.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    var onDocumentPicked: (ManagedStagedFile, String) -> Void
    var onError: (Error) -> Void

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
        Coordinator(onDocumentPicked: onDocumentPicked, onError: onError)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentPicked: (ManagedStagedFile, String) -> Void
        let onError: (Error) -> Void
        private let stageDocument: (URL) throws -> ManagedStagedFile

        init(
            onDocumentPicked: @escaping (ManagedStagedFile, String) -> Void,
            onError: @escaping (Error) -> Void,
            stageDocument: @escaping (URL) throws -> ManagedStagedFile = {
                try ManagedFileStore.shared.stage(
                    sourceURL: $0,
                    maximumSize: Constants.Attachments.maxFileSizeBytes
                )
            }
        ) {
            self.onDocumentPicked = onDocumentPicked
            self.onError = onError
            self.stageDocument = stageDocument
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let sourceURL = urls.first else { return }

            guard sourceURL.startAccessingSecurityScopedResource() else {
                return
            }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            stageDocument(at: sourceURL)
        }

        func stageDocument(at sourceURL: URL) {
            do {
                let stagedFile = try stageDocument(sourceURL)
                onDocumentPicked(stagedFile, sourceURL.lastPathComponent)
            } catch {
                onError(error)
            }
        }
    }
}
