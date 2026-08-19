//
//  DocumentPickerView.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    var onDocumentPicked: (ManagedStagedFile, String) -> Void

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
        Coordinator(onDocumentPicked: onDocumentPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentPicked: (ManagedStagedFile, String) -> Void

        init(onDocumentPicked: @escaping (ManagedStagedFile, String) -> Void) {
            self.onDocumentPicked = onDocumentPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let sourceURL = urls.first else { return }

            let fileName = sourceURL.lastPathComponent

            guard sourceURL.startAccessingSecurityScopedResource() else {
                return
            }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            do {
                let stagedFile = try ManagedFileStore.shared.stage(
                    sourceURL: sourceURL,
                    maximumSize: Constants.Attachments.maxFileSizeBytes
                )
                onDocumentPicked(stagedFile, fileName)
            } catch {
                #if DEBUG
                print("Failed to stage document: \(error)")
                #endif
            }
        }
    }
}
