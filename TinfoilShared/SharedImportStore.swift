import Foundation
import UniformTypeIdentifiers

struct SharedImportStore: @unchecked Sendable {
    private static let publicationBlockFileName = ".publication-blocked"
    private let fileManager: FileManager
    private let publicationDidBegin: (@Sendable () -> Void)?
    private let purgeDidBegin: (@Sendable () -> Void)?
    let inboxURL: URL

    init(
        fileManager: FileManager = .default,
        inboxURL: URL? = nil,
        publicationDidBegin: (@Sendable () -> Void)? = nil,
        purgeDidBegin: (@Sendable () -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        self.publicationDidBegin = publicationDidBegin
        self.purgeDidBegin = purgeDidBegin

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
        do {
            let byteCount = try BoundedFileIO.validatedSize(
                of: sourceURL,
                maximumSize: kind.maximumSizeBytes
            )
            return try enqueue(
                kind: kind,
                byteCount: byteCount,
                typeIdentifier: typeIdentifier,
                originalFileName: originalFileName
            ) { stagedURL in
                let copiedSize = try BoundedFileIO.copy(
                    from: sourceURL,
                    to: stagedURL,
                    maximumSize: kind.maximumSizeBytes
                )
                guard copiedSize == byteCount else {
                    throw SharedImportError.invalidFile
                }
            }
        } catch BoundedFileIOError.fileTooLarge(let size, _) {
            throw SharedImportError.fileTooLarge(kind: kind, size: size)
        } catch let error as SharedImportError {
            throw error
        } catch {
            throw SharedImportError.invalidFile
        }
    }

    @discardableResult
    func enqueue(
        data: Data,
        typeIdentifier: String,
        originalFileName: String
    ) throws -> SharedImportRequest {
        guard let kind = SharedImportClassifier.kind(
            typeIdentifier: typeIdentifier,
            fileName: originalFileName
        ) else {
            throw SharedImportError.unsupportedType
        }

        let byteCount = Int64(data.count)
        guard byteCount <= kind.maximumSizeBytes else {
            throw SharedImportError.fileTooLarge(kind: kind, size: byteCount)
        }

        return try enqueue(
            kind: kind,
            byteCount: byteCount,
            typeIdentifier: typeIdentifier,
            originalFileName: originalFileName
        ) { stagedURL in
            try data.write(to: stagedURL, options: .atomic)
        }
    }

    private func enqueue(
        kind: SharedImportKind,
        byteCount: Int64,
        typeIdentifier: String,
        originalFileName: String,
        writePayload: (URL) throws -> Void
    ) throws -> SharedImportRequest {

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

        return try withCoordinatedInboxWrite {
            guard !fileManager.fileExists(atPath: publicationBlockURL.path) else {
                throw SharedImportError.publicationBlocked
            }
            publicationDidBegin?()
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: nil
            )

            do {
                let stagedURL = temporaryDirectory.appendingPathComponent(stagedFileName)
                try writePayload(stagedURL)
                guard try BoundedFileIO.validatedSize(
                    of: stagedURL,
                    maximumSize: kind.maximumSizeBytes
                ) == byteCount else {
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
    }

    func pendingRequests() -> [SharedImportRequest] {
        removeStaleEntries()

        let directories = (try? fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories
            .compactMap { loadRequest(from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes abandoned hidden staging, stale malformed requests, and valid
    /// requests past their retention window without racing an active share.
    private func removeStaleEntries() {
        let staleCutoff = Date().addingTimeInterval(
            -SharedImportConfiguration.staleStagingLifetimeSeconds
        )
        let retentionCutoff = Date().addingTimeInterval(
            -SharedImportConfiguration.validRequestRetentionSeconds
        )
        let entries = (try? fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: []
        )) ?? []
        for url in entries {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey
            ])
            let entryDate = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            if name.hasPrefix(".") && name.hasSuffix(".tmp") {
                if entryDate < staleCutoff {
                    try? fileManager.removeItem(at: url)
                }
                continue
            }
            guard UUID(uuidString: name) != nil else { continue }
            if let request = loadRequest(from: url) {
                if request.createdAt < retentionCutoff {
                    try? fileManager.removeItem(at: url)
                }
            } else if entryDate < staleCutoff {
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

    func payloadData(for request: SharedImportRequest) throws -> Data {
        try BoundedFileIO.read(
            from: payloadURL(for: request),
            maximumSize: request.item.kind.maximumSizeBytes
        )
    }

    func removeRequest(id: UUID) throws {
        try withCoordinatedInboxWrite {
            try removeIfPresent(at: directoryURL(for: id))
        }
    }

    func purgeAllRequests() throws {
        try withCoordinatedInboxWrite {
            purgeDidBegin?()
            guard fileManager.fileExists(atPath: publicationBlockURL.path)
                || fileManager.createFile(atPath: publicationBlockURL.path, contents: Data()) else {
                throw SharedImportError.invalidFile
            }
            let entries = try fileManager.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            for url in entries {
                let name = url.lastPathComponent
                if UUID(uuidString: name) != nil
                    || (name.hasPrefix(".") && name.hasSuffix(".tmp")) {
                    try removeIfPresent(at: url)
                }
            }
        }
    }

    func allowPublications() throws {
        try withCoordinatedInboxWrite {
            try removeIfPresent(at: publicationBlockURL)
        }
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

        guard let data = try? BoundedFileIO.read(
                  from: manifestURL,
                  maximumSize: SharedImportConfiguration.maximumManifestSizeBytes
              ),
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

    private var publicationBlockURL: URL {
        inboxURL.appendingPathComponent(Self.publicationBlockFileName)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw SharedImportError.invalidFile
        }
        return size.int64Value
    }

    private func removeIfPresent(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        }
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

    private func withCoordinatedInboxWrite<T>(_ operation: () throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: inboxURL,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            result = Result { try operation() }
        }
        if let result {
            return try result.get()
        }
        throw coordinationError ?? SharedImportError.invalidFile
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
