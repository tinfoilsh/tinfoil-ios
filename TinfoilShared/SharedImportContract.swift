import Foundation
import UniformTypeIdentifiers

enum SharedImportConfiguration {
    static let appGroupIdentifier = "group.sh.tinfoil.TinfoilChat"
    static let inboxDirectoryName = "ShareInbox"
    static let manifestFileName = "request.json"
    static let maximumFileNameLength = 120
    static let maximumImageSizeBytes: Int64 = 10 * 1024 * 1024
    static let maximumDocumentSizeBytes: Int64 = 20 * 1024 * 1024
    /// Hidden staging directories older than this are treated as abandoned
    /// by an interrupted share and swept from the app-group inbox.
    static let staleStagingLifetimeSeconds: TimeInterval = 24 * 60 * 60
    static let supportedDocumentExtensions: Set<String> = [
        "pdf", "docx", "pptx", "xlsx", "txt", "md", "csv", "html", "json", "xml",
    ]
}

enum SharedImportKind: String, Codable, Equatable {
    case image
    case document

    var maximumSizeBytes: Int64 {
        switch self {
        case .image:
            return SharedImportConfiguration.maximumImageSizeBytes
        case .document:
            return SharedImportConfiguration.maximumDocumentSizeBytes
        }
    }
}

struct SharedImportRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let item: SharedImportItem
}

struct SharedImportItem: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: SharedImportKind
    let typeIdentifier: String
    let originalFileName: String
    let stagedFileName: String
    let byteCount: Int64
}

enum SharedImportClassifier {
    static func kind(typeIdentifier: String, fileName: String?) -> SharedImportKind? {
        let contentType = UTType(typeIdentifier)
        if contentType?.conforms(to: .image) == true {
            return .image
        }

        let fileExtension = fileName
            .map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? contentType?.preferredFilenameExtension?.lowercased()

        guard let fileExtension,
              SharedImportConfiguration.supportedDocumentExtensions.contains(fileExtension) else {
            return nil
        }

        guard let contentType else {
            return .document
        }
        if contentType == .data || contentType == .item || contentType == .content {
            return .document
        }
        guard let inferredType = UTType(filenameExtension: fileExtension),
              contentType.conforms(to: inferredType) || inferredType.conforms(to: contentType) else {
            return nil
        }
        return .document
    }
}

enum SharedImportError: LocalizedError {
    case sharedContainerUnavailable
    case unsupportedType
    case invalidFile
    case fileTooLarge(kind: SharedImportKind, size: Int64)
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            return "Tinfoil's shared storage is unavailable."
        case .unsupportedType:
            return "This file type is not supported by Tinfoil."
        case .invalidFile:
            return "The shared file could not be read."
        case .fileTooLarge(let kind, let size):
            let maximumSize = kind.maximumSizeBytes / 1_048_576
            let sizeInMegabytes = Double(size) / 1_048_576
            return String(
                format: "This %@ is too large (%.1f MB). Maximum is %lld MB.",
                kind == .image ? "image" : "file",
                sizeInMegabytes,
                maximumSize
            )
        case .invalidRequest:
            return "The shared file request is invalid."
        }
    }
}
