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

        let fileSize = try fileSize(at: url)
        guard fileSize <= Constants.Attachments.maxFileSizeBytes else {
            throw ProcessingError.fileTooLarge(fileSize)
        }

        return try await Task.detached(priority: .userInitiated) {
            switch fileExtension {
            case "pdf":
                return try self.extractTextFromPDF(at: url)
            case "txt", "md", "csv", "html":
                return try self.readPlainText(at: url)
            default:
                throw ProcessingError.unsupportedFormat(fileExtension)
            }
        }.value
    }

    private func extractTextFromPDF(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
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
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw ProcessingError.fileReadFailed
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.textExtractionFailed
        }

        return text
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
}
