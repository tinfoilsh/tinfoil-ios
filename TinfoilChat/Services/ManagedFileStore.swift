import Foundation

final class ManagedFileHandle: @unchecked Sendable {
    let url: URL
    let fileName: String
    let size: Int64

    private let store: ManagedFileStore
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(url: URL, fileName: String, size: Int64, store: ManagedFileStore) {
        self.url = url
        self.fileName = fileName
        self.size = size
        self.store = store
    }

    deinit {
        try? release()
    }

    func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        try store.removeFile(at: url)
        isReleased = true
    }
}

final class ManagedFileStore: @unchecked Sendable {
    static let shared = ManagedFileStore()

    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ManagedFileStaging", isDirectory: true)
    }

    func stage(sourceURL: URL, fileName: String) throws -> ManagedFileHandle {
        try prepareDirectory()
        let destinationURL = directoryURL.appendingPathComponent(destinationName(for: sourceURL))
        let size = try BoundedFileIO.copy(
            from: sourceURL,
            to: destinationURL,
            maximumBytes: Constants.Attachments.maxFileSizeBytes,
            destinationAttributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )

        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destinationURL.path
            )
            try excludeFromBackup(destinationURL)
            return ManagedFileHandle(url: destinationURL, fileName: fileName, size: size, store: self)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    fileprivate func removeFile(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
        try excludeFromBackup(directoryURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func destinationName(for sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension
        let safeExtension = fileExtension.count <= 16 && fileExtension.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        } ? fileExtension : ""
        return UUID().uuidString + (safeExtension.isEmpty ? "" : ".\(safeExtension)")
    }
}
