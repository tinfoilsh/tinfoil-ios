import Foundation

final class ManagedStagedFile: @unchecked Sendable {
    let id: UUID
    let url: URL
    let originalSize: Int

    private let store: ManagedFileStore
    private let lock = NSLock()
    private var isDiscarded = false

    fileprivate init(id: UUID, url: URL, originalSize: Int, store: ManagedFileStore) {
        self.id = id
        self.url = url
        self.originalSize = originalSize
        self.store = store
    }

    deinit {
        discard()
    }

    @discardableResult
    func discard() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDiscarded else { return true }
        guard store.discard(id: id, url: url) else { return false }
        isDiscarded = true
        return true
    }
}

final class ManagedFileStore: @unchecked Sendable {
    static let shared = ManagedFileStore()
    static let stagingDirectoryName = "ManagedFileStaging"

    let rootURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.rootURL = applicationSupport.appendingPathComponent(
                Self.stagingDirectoryName,
                isDirectory: true
            )
        }
    }

    func stage(sourceURL: URL, maximumSize: Int64) throws -> ManagedStagedFile {
        try prepareRoot()
        let id = UUID()
        let destinationURL = fileURL(id: id, fileExtension: sourceURL.pathExtension)
        do {
            let size = try BoundedFileIO.copy(
                from: sourceURL,
                to: destinationURL,
                maximumSize: maximumSize,
                destinationAttributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            try protectAndExcludeFromBackup(destinationURL)
            return ManagedStagedFile(id: id, url: destinationURL, originalSize: Int(size), store: self)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func stage(data: Data, fileExtension: String?, maximumSize: Int64) throws -> ManagedStagedFile {
        guard Int64(data.count) <= maximumSize else {
            throw BoundedFileIOError.fileTooLarge(
                size: Int64(data.count),
                maximum: maximumSize
            )
        }
        try prepareRoot()
        let id = UUID()
        let destinationURL = fileURL(id: id, fileExtension: fileExtension)
        do {
            try data.write(to: destinationURL, options: [.atomic])
            guard try BoundedFileIO.validatedSize(
                of: destinationURL,
                maximumSize: maximumSize
            ) == Int64(data.count) else {
                throw BoundedFileIOError.invalidFile
            }
            try protectAndExcludeFromBackup(destinationURL)
            return ManagedStagedFile(
                id: id,
                url: destinationURL,
                originalSize: data.count,
                store: self
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func sweepOnStartup() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        var firstError: Error?
        for entry in entries {
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func owns(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        guard parent == rootURL.standardizedFileURL else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: stem) != nil
    }

    fileprivate func discard(id: UUID, url: URL) -> Bool {
        guard owns(url), url.deletingPathExtension().lastPathComponent == id.uuidString.lowercased() else {
            return false
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private func fileURL(id: UUID, fileExtension: String?) -> URL {
        let suffix = fileExtension.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let fileName = suffix.map { "\(id.uuidString.lowercased()).\($0)" }
            ?? id.uuidString.lowercased()
        return rootURL.appendingPathComponent(fileName)
    }

    private func prepareRoot() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try protectAndExcludeFromBackup(rootURL)
    }

    private func protectAndExcludeFromBackup(_ url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }
}
