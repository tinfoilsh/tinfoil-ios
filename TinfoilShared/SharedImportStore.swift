import Foundation
import UniformTypeIdentifiers

struct SharedImportStore {
    private let fileManager: FileManager
    let inboxURL: URL

    init(fileManager: FileManager = .default, inboxURL: URL? = nil) throws {
        self.fileManager = fileManager

        if let inboxURL {
            self.inboxURL = inboxURL
        } else {
            guard let containerURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: SharedImportConfiguration.appGroupIdentifier
            ) else {
                throw SharedImportError.sharedContainerUnavailable
            }
            self.inboxURL = containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(SharedImportConfiguration.inboxDirectoryName, isDirectory: true)
        }

        try fileManager.createDirectory(
            at: self.inboxURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    @discardableResult
    func enqueue(
        sourceURL: URL,
        typeIdentifier: String,
        originalFileName: String
    ) throws -> SharedImportRequest {
        guard let kind = SharedImportClassifier.kind(
            typeIdentifier: typeIdentifier,
            fileName: originalFileName
        ) else {
            throw SharedImportError.unsupportedType
        }

        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw SharedImportError.invalidFile
        }

        let byteCount = Int64(sourceValues.fileSize ?? 0)
        guard byteCount <= kind.maximumSizeBytes else {
            throw SharedImportError.fileTooLarge(kind: kind, size: byteCount)
        }

        let requestID = UUID()
        let itemID = UUID()
        let fileName = Self.sanitizedFileName(originalFileName)
        let stagedFileName = Self.stagedFileName(
            id: itemID,
            originalFileName: fileName,
            typeIdentifier: typeIdentifier
        )
        let request = SharedImportRequest(
            id: requestID,
            createdAt: Date(),
            item: SharedImportItem(
                id: itemID,
                kind: kind,
                typeIdentifier: typeIdentifier,
                originalFileName: fileName,
                stagedFileName: stagedFileName,
                byteCount: byteCount
            )
        )

        let temporaryDirectory = inboxURL.appendingPathComponent(
            ".\(requestID.uuidString.lowercased()).tmp",
            isDirectory: true
        )
        let requestDirectory = directoryURL(for: requestID)

        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: nil
        )

        do {
            let stagedURL = temporaryDirectory.appendingPathComponent(stagedFileName)
            try fileManager.copyItem(at: sourceURL, to: stagedURL)

            let copiedSize = try fileSize(at: stagedURL)
            guard copiedSize == byteCount else {
                throw SharedImportError.invalidFile
            }

            let manifestURL = temporaryDirectory.appendingPathComponent(
                SharedImportConfiguration.manifestFileName
            )
            let encoder = JSONEncoder()
            try encoder.encode(request).write(to: manifestURL, options: .atomic)

            protectAndExcludeFromBackup(stagedURL)
            protectAndExcludeFromBackup(manifestURL)
            protectAndExcludeFromBackup(temporaryDirectory)
            try fileManager.moveItem(at: temporaryDirectory, to: requestDirectory)
            return request
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    func pendingRequests() -> [SharedImportRequest] {
        removeStaleTemporaryDirectories()

        let directories = (try? fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories
            .compactMap { loadRequest(from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes staging directories abandoned by an interrupted share (the
    /// extension was killed between copy and publish), so they don't retain
    /// app-group storage indefinitely. Only directories older than the
    /// staging lifetime are removed, to never race a share in progress.
    private func removeStaleTemporaryDirectories() {
        let cutoff = Date().addingTimeInterval(
            -SharedImportConfiguration.staleStagingLifetimeSeconds
        )
        let entries = (try? fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        )) ?? []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp") else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            if created < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func payloadURL(for request: SharedImportRequest) throws -> URL {
        guard request.item.stagedFileName == URL(
            fileURLWithPath: request.item.stagedFileName
        ).lastPathComponent else {
            throw SharedImportError.invalidRequest
        }

        let payloadURL = directoryURL(for: request.id)
            .appendingPathComponent(request.item.stagedFileName)
        let values = try payloadURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              try fileSize(at: payloadURL) == request.item.byteCount,
              request.item.byteCount <= request.item.kind.maximumSizeBytes,
              SharedImportClassifier.kind(
                typeIdentifier: request.item.typeIdentifier,
                fileName: request.item.originalFileName
              ) == request.item.kind else {
            throw SharedImportError.invalidRequest
        }
        return payloadURL
    }

    func removeRequest(id: UUID) {
        try? fileManager.removeItem(at: directoryURL(for: id))
    }

    static func sanitizedFileName(_ fileName: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: fileName).lastPathComponent
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " ._-")
        )
        let sanitizedScalars = lastPathComponent.unicodeScalars.map {
            allowedCharacters.contains($0) ? Character(String($0)) : "_"
        }
        let sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = sanitized.isEmpty ? "Shared File" : sanitized
        let maxLength = SharedImportConfiguration.maximumFileNameLength
        guard fallbackName.count > maxLength else { return fallbackName }

        // Truncate the stem, never the extension: enqueue and payload
        // validation both classify by the final extension, so dropping
        // it would stage a file that later fails validation silently.
        let fileExtension = URL(fileURLWithPath: fallbackName).pathExtension
        guard !fileExtension.isEmpty, fileExtension.count + 1 < maxLength else {
            return String(fallbackName.prefix(maxLength))
        }
        let stem = URL(fileURLWithPath: fallbackName)
            .deletingPathExtension()
            .lastPathComponent
        return "\(stem.prefix(maxLength - fileExtension.count - 1)).\(fileExtension)"
    }

    private func loadRequest(from directoryURL: URL) -> SharedImportRequest? {
        guard UUID(uuidString: directoryURL.lastPathComponent) != nil else {
            return nil
        }

        let manifestURL = directoryURL.appendingPathComponent(
            SharedImportConfiguration.manifestFileName
        )
        let decoder = JSONDecoder()

        guard let data = try? Data(contentsOf: manifestURL),
              let request = try? decoder.decode(SharedImportRequest.self, from: data),
              directoryURL == self.directoryURL(for: request.id),
              (try? payloadURL(for: request)) != nil else {
            return nil
        }
        return request
    }

    private func directoryURL(for requestID: UUID) -> URL {
        inboxURL.appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw SharedImportError.invalidFile
        }
        return size.int64Value
    }

    private func protectAndExcludeFromBackup(_ url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }

    private static func stagedFileName(
        id: UUID,
        originalFileName: String,
        typeIdentifier: String
    ) -> String {
        let originalExtension = URL(fileURLWithPath: originalFileName).pathExtension.lowercased()
        let fileExtension = originalExtension.isEmpty
            ? UTType(typeIdentifier)?.preferredFilenameExtension
            : originalExtension

        guard let fileExtension, !fileExtension.isEmpty else {
            return id.uuidString.lowercased()
        }
        return "\(id.uuidString.lowercased()).\(fileExtension)"
    }
}
