import Darwin
import Foundation
import UniformTypeIdentifiers

struct SharedImportStore {
    private static let enqueueLock = NSLock()

    private let fileManager: FileManager
    private let currentDate: () -> Date
    private let maximumPendingRequestCount: Int
    private let maximumPendingPayloadBytes: Int64
    let inboxURL: URL

    init(
        fileManager: FileManager = .default,
        inboxURL: URL? = nil,
        currentDate: @escaping () -> Date = Date.init,
        maximumPendingRequestCount: Int = SharedImportConfiguration.maximumPendingRequestCount,
        maximumPendingPayloadBytes: Int64 = SharedImportConfiguration.maximumPendingPayloadBytes
    ) throws {
        self.fileManager = fileManager
        self.currentDate = currentDate
        self.maximumPendingRequestCount = maximumPendingRequestCount
        self.maximumPendingPayloadBytes = maximumPendingPayloadBytes

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
        let kind = try classifiedKind(
            typeIdentifier: typeIdentifier,
            originalFileName: originalFileName
        )
        let byteCount: Int64
        do {
            byteCount = try BoundedFileIO.size(of: sourceURL, maximumBytes: kind.maximumSizeBytes)
        } catch BoundedFileIO.Error.fileTooLarge(let size, _) {
            throw SharedImportError.fileTooLarge(kind: kind, size: size)
        }
        let item = makeItem(
            kind: kind,
            typeIdentifier: typeIdentifier,
            originalFileName: originalFileName,
            byteCount: byteCount
        )
        return try withExclusiveEnqueueLock {
            try enforcePendingLimits(addingPayloadBytes: byteCount)
            return try publish(requestID: UUID(), item: item) { destinationURL in
                do {
                    return try BoundedFileIO.copy(
                        from: sourceURL,
                        to: destinationURL,
                        maximumBytes: item.kind.maximumSizeBytes
                    )
                } catch BoundedFileIO.Error.fileTooLarge(let size, _) {
                    throw SharedImportError.fileTooLarge(kind: item.kind, size: size)
                }
            }
        }
    }

    @discardableResult
    func enqueue(
        data: Data,
        typeIdentifier: String,
        originalFileName: String
    ) throws -> SharedImportRequest {
        let kind = try classifiedKind(
            typeIdentifier: typeIdentifier,
            originalFileName: originalFileName
        )
        let byteCount = Int64(data.count)
        guard byteCount <= kind.maximumSizeBytes else {
            throw SharedImportError.fileTooLarge(kind: kind, size: byteCount)
        }
        let item = makeItem(
            kind: kind,
            typeIdentifier: typeIdentifier,
            originalFileName: originalFileName,
            byteCount: byteCount
        )

        return try withExclusiveEnqueueLock {
            try enforcePendingLimits(addingPayloadBytes: byteCount)
            return try publish(requestID: UUID(), item: item) { destinationURL in
                try data.write(to: destinationURL, options: .withoutOverwriting)
                return try BoundedFileIO.size(
                    of: destinationURL,
                    maximumBytes: item.kind.maximumSizeBytes
                )
            }
        }
    }

    private func enforcePendingLimits(addingPayloadBytes byteCount: Int64) throws {
        let pendingRequests = pendingRequests()
        guard pendingRequests.count < maximumPendingRequestCount else {
            throw SharedImportError.tooManyPendingRequests(maximum: maximumPendingRequestCount)
        }

        var aggregateBytes: Int64 = 0
        for request in pendingRequests {
            let result = aggregateBytes.addingReportingOverflow(request.item.byteCount)
            guard !result.overflow else {
                throw SharedImportError.pendingPayloadQuotaExceeded(
                    maximumBytes: maximumPendingPayloadBytes
                )
            }
            aggregateBytes = result.partialValue
        }
        guard byteCount <= maximumPendingPayloadBytes,
              aggregateBytes <= maximumPendingPayloadBytes - byteCount else {
            throw SharedImportError.pendingPayloadQuotaExceeded(
                maximumBytes: maximumPendingPayloadBytes
            )
        }
    }

    private func withExclusiveEnqueueLock<T>(_ operation: () throws -> T) throws -> T {
        Self.enqueueLock.lock()
        defer { Self.enqueueLock.unlock() }

        let lockURL = inboxURL.appendingPathComponent(SharedImportConfiguration.enqueueLockFileName)
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw SharedImportError.invalidFile }
        defer { Darwin.close(descriptor) }

        while Darwin.flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SharedImportError.invalidFile }
        }
        defer { _ = Darwin.flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func publish(
        requestID: UUID,
        item: SharedImportItem,
        writePayload: (URL) throws -> Int64
    ) throws -> SharedImportRequest {
        let request = SharedImportRequest(id: requestID, createdAt: currentDate(), item: item)

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
            let stagedURL = temporaryDirectory.appendingPathComponent(item.stagedFileName)
            let copiedSize = try writePayload(stagedURL)
            guard copiedSize == item.byteCount else {
                throw SharedImportError.invalidFile
            }

            let manifestURL = temporaryDirectory.appendingPathComponent(
                SharedImportConfiguration.manifestFileName
            )
            let encoder = JSONEncoder()
            let manifestData = try encoder.encode(request)
            guard Int64(manifestData.count) <= SharedImportConfiguration.maximumManifestSizeBytes else {
                throw SharedImportError.invalidRequest
            }
            try manifestData.write(to: manifestURL, options: .atomic)

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
            .compactMap { directoryURL in
                let request = loadRequest(from: directoryURL)
                if request == nil {
                    removeMalformedRequestDirectoryIfStale(directoryURL)
                }
                return request
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes staging directories abandoned by an interrupted share (the
    /// extension was killed between copy and publish), so they don't retain
    /// app-group storage indefinitely. Only directories older than the
    /// staging lifetime are removed, to never race a share in progress.
    private func removeStaleTemporaryDirectories() {
        let cutoff = currentDate().addingTimeInterval(
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
        guard try BoundedFileIO.size(
            of: payloadURL,
            maximumBytes: request.item.kind.maximumSizeBytes
        ) == request.item.byteCount,
              SharedImportClassifier.kind(
                typeIdentifier: request.item.typeIdentifier,
                fileName: request.item.originalFileName
              ) == request.item.kind else {
            throw SharedImportError.invalidRequest
        }
        return payloadURL
    }

    func payloadData(for request: SharedImportRequest) throws -> Data {
        let payloadURL = try payloadURL(for: request)
        return try BoundedFileIO.read(
            from: payloadURL,
            maximumBytes: request.item.kind.maximumSizeBytes
        )
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

        guard let data = try? BoundedFileIO.read(
            from: manifestURL,
            maximumBytes: SharedImportConfiguration.maximumManifestSizeBytes
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

    private func removeMalformedRequestDirectoryIfStale(_ directoryURL: URL) {
        guard UUID(uuidString: directoryURL.lastPathComponent) != nil,
              (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return
        }
        let cutoff = currentDate().addingTimeInterval(
            -SharedImportConfiguration.staleStagingLifetimeSeconds
        )
        guard let created = (try? directoryURL.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate else { return }
        if created < cutoff {
            try? fileManager.removeItem(at: directoryURL)
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

    private func classifiedKind(
        typeIdentifier: String,
        originalFileName: String
    ) throws -> SharedImportKind {
        guard let kind = SharedImportClassifier.kind(
            typeIdentifier: typeIdentifier,
            fileName: originalFileName
        ) else {
            throw SharedImportError.unsupportedType
        }
        return kind
    }

    private func makeItem(
        kind: SharedImportKind,
        typeIdentifier: String,
        originalFileName: String,
        byteCount: Int64
    ) -> SharedImportItem {
        let itemID = UUID()
        let fileName = Self.sanitizedFileName(originalFileName)
        return SharedImportItem(
            id: itemID,
            kind: kind,
            typeIdentifier: typeIdentifier,
            originalFileName: fileName,
            stagedFileName: Self.stagedFileName(
                id: itemID,
                originalFileName: fileName,
                typeIdentifier: typeIdentifier
            ),
            byteCount: byteCount
        )
    }
}
