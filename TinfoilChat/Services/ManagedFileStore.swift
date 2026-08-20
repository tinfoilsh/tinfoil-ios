import Foundation

final class ManagedStagedFile: @unchecked Sendable {
    let id: UUID
    let url: URL
    let fileName: String

    private let store: ManagedFileStore
    private let lock = NSLock()
    private var isDiscarded = false

    fileprivate init(id: UUID, url: URL, fileName: String, store: ManagedFileStore) {
        self.id = id
        self.url = url
        self.fileName = fileName
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

    private let fileManager: FileManager
    private let directoryURL: URL
    private let removeItem: (URL) throws -> Void
    private let lock = NSLock()
    private var activeIDs: Set<UUID> = []

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        removeItem: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.removeItem = removeItem ?? fileManager.removeItem(at:)
        self.directoryURL = directoryURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    func stage(sourceURL: URL, fileName: String) throws -> ManagedStagedFile {
        let id = UUID()
        lock.lock()
        activeIDs.insert(id)
        lock.unlock()
        let destinationURL = directoryURL.appendingPathComponent(destinationName(id: id, for: sourceURL))

        do {
            try prepareDirectory()
            try BoundedFileIO.copy(
                from: sourceURL,
                to: destinationURL,
                maximumBytes: Constants.Attachments.maxFileSizeBytes,
                destinationAttributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            try excludeFromBackup(destinationURL)
            let stagedFile = ManagedStagedFile(
                id: id,
                url: destinationURL,
                fileName: fileName,
                store: self
            )
            return stagedFile
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            lock.lock()
            activeIDs.remove(id)
            lock.unlock()
            throw error
        }
    }

    func sweepOnStartup() -> [Error] {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        } catch {
            return [error]
        }

        var failures: [Error] = []
        for child in children {
            let stem = child.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem), activeIDs.contains(id) {
                continue
            }
            do {
                try removeItem(child)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                failures.append(error)
            }
        }
        return failures
    }

    func owns(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == directoryURL.standardizedFileURL else {
            return false
        }
        let stem = standardizedURL.deletingPathExtension().lastPathComponent
        guard let id = UUID(uuidString: stem) else { return false }
        return stem == id.uuidString.lowercased()
    }

    func discard(id: UUID, url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let stem = url.deletingPathExtension().lastPathComponent
        guard owns(url), stem == id.uuidString.lowercased() else { return false }
        do {
            try removeItem(url)
            activeIDs.remove(id)
            return true
        } catch CocoaError.fileNoSuchFile {
            activeIDs.remove(id)
            return true
        } catch {
            return false
        }
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
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func destinationName(id: UUID, for sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension
        let safeExtension = fileExtension.count <= 16 && fileExtension.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        } ? fileExtension : ""
        return id.uuidString.lowercased() + (safeExtension.isEmpty ? "" : ".\(safeExtension.lowercased())")
    }
}
