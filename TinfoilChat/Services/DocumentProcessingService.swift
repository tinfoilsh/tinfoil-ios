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

        switch fileExtension {
        case "pdf":
            return try await Task.detached(priority: .userInitiated) {
                try self.extractTextFromPDF(at: url)
            }.value
        case "txt", "md", "csv", "html", "json", "xml":
            return try await Task.detached(priority: .userInitiated) {
                try self.readPlainText(at: url)
            }.value
        default:
            return try await DocumentConversionService.shared.convertToMarkdown(url: url, filename: url.lastPathComponent)
        }
    }

    private func extractTextFromPDF(at url: URL) throws -> String {
        let data = try boundedData(from: url)
        guard let document = PDFDocument(data: data) else {
            throw ProcessingError.textExtractionFailed
        }

        var fullText = ""
        for pageIndex in 0..<document.pageCount {
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
        let data = try boundedData(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProcessingError.fileReadFailed
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.textExtractionFailed
        }

        return text
    }

    private func boundedData(from url: URL) throws -> Data {
        do {
            return try BoundedFileIO.read(
                from: url,
                maximumBytes: Constants.Attachments.maxFileSizeBytes
            )
        } catch BoundedFileIO.Error.fileTooLarge(let size, _) {
            throw ProcessingError.fileTooLarge(size)
        }
    }
}
