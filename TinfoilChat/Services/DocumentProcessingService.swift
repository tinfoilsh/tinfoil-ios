//
//  DocumentProcessingService.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import PDFKit

final class DocumentProcessingService {
    static let shared = DocumentProcessingService()
    private init() {}

    enum ProcessingError: LocalizedError {
        case fileTooLarge(Int64)
        case unsupportedFormat(String)
        case textExtractionFailed
        case fileReadFailed

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let size):
                let sizeMB = Double(size) / 1_048_576
                return String(format: "File is too large (%.1f MB). Maximum is %d MB.", sizeMB, Constants.Attachments.maxFileSizeBytes / 1_048_576)
            case .unsupportedFormat(let ext):
                return "Unsupported file format: .\(ext)"
            case .textExtractionFailed:
                return "Could not extract text from this file."
            case .fileReadFailed:
                return "Could not read the file."
            }
        }
    }

    func extractText(from url: URL) async throws -> String {
        let fileExtension = url.pathExtension.lowercased()

        guard Constants.Attachments.supportedDocumentExtensions.contains(fileExtension) else {
            throw ProcessingError.unsupportedFormat(fileExtension)
        }

        do {
            _ = try BoundedFileIO.validatedSize(
                of: url,
                maximumSize: Constants.Attachments.maxFileSizeBytes
            )
        } catch BoundedFileIOError.fileTooLarge(let size, _) {
            throw ProcessingError.fileTooLarge(size)
        }

        switch fileExtension {
        case "pdf":
            let extractionTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try self.extractTextFromPDF(at: url)
            }
            return try await withTaskCancellationHandler {
                try await extractionTask.value
            } onCancel: {
                extractionTask.cancel()
            }
        case "txt", "md", "csv", "html", "json", "xml":
            let extractionTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try self.readPlainText(at: url)
            }
            return try await withTaskCancellationHandler {
                try await extractionTask.value
            } onCancel: {
                extractionTask.cancel()
            }
        default:
            return try await DocumentConversionService.shared.convertToMarkdown(url: url, filename: url.lastPathComponent)
        }
    }

    private func extractTextFromPDF(at url: URL) throws -> String {
        try Task.checkCancellation()
        let data = try BoundedFileIO.read(
            from: url,
            maximumSize: Constants.Attachments.maxFileSizeBytes
        )
        guard let document = PDFDocument(data: data) else {
            throw ProcessingError.textExtractionFailed
        }

        var fullText = ""
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { continue }
            if let pageText = page.string {
                if !fullText.isEmpty {
                    fullText += "\n\n"
                }
                fullText += pageText
            }
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.textExtractionFailed
        }

        return fullText
    }

    private func readPlainText(at url: URL) throws -> String {
        try Task.checkCancellation()
        let data: Data
        do {
            data = try BoundedFileIO.read(
                from: url,
                maximumSize: Constants.Attachments.maxFileSizeBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProcessingError.fileReadFailed
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProcessingError.fileReadFailed
        }
        try Task.checkCancellation()

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.textExtractionFailed
        }

        return text
    }
}
