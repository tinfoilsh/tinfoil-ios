//
//  DocumentPickerView.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    var onDocumentPicked: (ManagedFileHandle) -> Void
    var onError: (Error) -> Void

    init(
        onDocumentPicked: @escaping (ManagedFileHandle) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onDocumentPicked = onDocumentPicked
        self.onError = onError
    }

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
        let onDocumentPicked: (ManagedFileHandle) -> Void
        let onError: (Error) -> Void

        init(
            onDocumentPicked: @escaping (ManagedFileHandle) -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.onDocumentPicked = onDocumentPicked
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let sourceURL = urls.first else { return }

            let fileName = sourceURL.lastPathComponent

            guard sourceURL.startAccessingSecurityScopedResource() else {
                onError(BoundedFileIO.Error.readFailed)
                return
            }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            do {
                let handle = try ManagedFileStore.shared.stage(sourceURL: sourceURL, fileName: fileName)
                onDocumentPicked(handle)
            } catch {
                onError(error)
            }
        }
    }
}
