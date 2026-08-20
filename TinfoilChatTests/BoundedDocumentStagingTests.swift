import Foundation
import Testing
@testable import TinfoilChat

@Suite("Bounded Document Staging Tests")
struct BoundedDocumentStagingTests {
    @Test("Bounded file I/O copies and reads regular files")
    func copiesAndReadsRegularFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        let data = Data(repeating: 0x41, count: BoundedFileIO.chunkSize * 2 + 17)
        try data.write(to: source)

        let copiedSize = try BoundedFileIO.copy(
            from: source,
            to: destination,
            maximumBytes: Int64(data.count)
        )

        #expect(copiedSize == Int64(data.count))
        #expect(try BoundedFileIO.read(from: destination, maximumBytes: Int64(data.count)) == data)
    }

    @Test("Bounded file I/O rejects non-regular and oversized files")
    func rejectsUnsafeSources() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let symlink = directory.appendingPathComponent("source-link.txt")
        try Data("too large".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)

        #expect(throws: BoundedFileIO.Error.notRegularFile) {
            _ = try BoundedFileIO.read(from: symlink, maximumBytes: 100)
        }
        #expect(throws: BoundedFileIO.Error.notRegularFile) {
            _ = try BoundedFileIO.read(from: directory, maximumBytes: 100)
        }
        #expect(throws: BoundedFileIO.Error.fileTooLarge(size: 9, maximum: 8)) {
            _ = try BoundedFileIO.read(from: source, maximumBytes: 8)
        }
    }

    @Test("Bounded file I/O preserves an existing destination")
    func preservesExistingDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)

        #expect(throws: BoundedFileIO.Error.destinationExists) {
            _ = try BoundedFileIO.copy(from: source, to: destination, maximumBytes: 100)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "existing")
    }

    @Test("Bounded copy rejects same-size in-place source changes")
    func rejectsSameSizeSourceChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        let sourceData = Data(repeating: 0x41, count: BoundedFileIO.chunkSize * 2)
        try sourceData.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: source.path
        )
        var didModifySource = false

        #expect(throws: BoundedFileIO.Error.fileChanged) {
            _ = try BoundedFileIO.copy(
                from: source,
                to: destination,
                maximumBytes: Int64(sourceData.count),
                onReadChunk: {
                    guard !didModifySource else { return }
                    didModifySource = true
                    let handle = try FileHandle(forWritingTo: source)
                    try handle.write(contentsOf: Data([0x42]))
                    try handle.close()
                }
            )
        }

        #expect(didModifySource)
        #expect(try BoundedFileIO.size(of: source, maximumBytes: Int64(sourceData.count)) == Int64(sourceData.count))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Managed files are protected, excluded from backup, and explicitly released")
    func managesStagedFileLifecycle() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("provider-owned.txt")
        let stagingDirectory = directory.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        let sourceData = Data("managed content".utf8)
        try sourceData.write(to: source)
        let store = ManagedFileStore(directoryURL: stagingDirectory)

        let handle = try store.stage(sourceURL: source, fileName: "document.txt")

        #expect(handle.fileName == "document.txt")
        #expect(FileManager.default.fileExists(atPath: handle.url.path))
        #expect(try handle.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: handle.url.path)
        #expect((attributes[.size] as? NSNumber)?.int64Value == Int64(sourceData.count))
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #expect(try Data(contentsOf: handle.url) == sourceData)

        #expect(handle.discard())
        #expect(!FileManager.default.fileExists(atPath: handle.url.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(handle.discard())
    }

    @Test("Managed discard never removes files outside staging")
    func managedDiscardIsRestrictedToOwnedDirectChildren() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingDirectory = directory.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        let providerFile = directory.appendingPathComponent("provider.txt")
        try Data("provider".utf8).write(to: providerFile)
        let store = ManagedFileStore(directoryURL: stagingDirectory)
        let stagedFile = try store.stage(sourceURL: providerFile, fileName: "provider.txt")

        #expect(store.owns(stagedFile.url))
        #expect(!store.owns(providerFile))
        #expect(!store.owns(stagingDirectory.appendingPathComponent("not-a-uuid.txt")))
        #expect(!store.discard(id: stagedFile.id, url: providerFile))
        #expect(FileManager.default.fileExists(atPath: providerFile.path))
        #expect(stagedFile.discard())
    }

    @Test("Startup sweep removes only staging children and reports individual failures")
    func startupSweepIsScopedAndReportsFailures() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingDirectory = directory.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        let providerFile = directory.appendingPathComponent("provider.txt")
        try Data("provider".utf8).write(to: providerFile)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        var blockedURL: URL?
        let store = ManagedFileStore(
            directoryURL: stagingDirectory,
            removeItem: { url in
                if url == blockedURL {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        let removedURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).txt")
        let failedURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).txt")
        let unrelatedChild = stagingDirectory.appendingPathComponent("keep.txt")
        let nestedDirectory = stagingDirectory.appendingPathComponent("nested", isDirectory: true)
        try Data("first".utf8).write(to: removedURL)
        try Data("second".utf8).write(to: failedURL)
        try Data("keep".utf8).write(to: unrelatedChild)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        blockedURL = failedURL

        let failures = store.sweepOnStartup()

        #expect(!FileManager.default.fileExists(atPath: removedURL.path))
        #expect(FileManager.default.fileExists(atPath: failedURL.path))
        #expect(failures.count == 1)
        #expect((failures.first as? CocoaError)?.code == .fileWriteNoPermission)
        #expect(!FileManager.default.fileExists(atPath: unrelatedChild.path))
        #expect(!FileManager.default.fileExists(atPath: nestedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: providerFile.path))
    }

    @Test("Document processing uses bounded regular-file reads")
    func processingRejectsUnsafeAndOversizedFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textFile = directory.appendingPathComponent("document.txt")
        try Data("bounded text".utf8).write(to: textFile)

        let text = try await DocumentProcessingService.shared.extractText(from: textFile)
        #expect(text == "bounded text")

        let symlink = directory.appendingPathComponent("document-link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: textFile)
        await #expect(throws: BoundedFileIO.Error.notRegularFile) {
            _ = try await DocumentProcessingService.shared.extractText(from: symlink)
        }

        let oversized = directory.appendingPathComponent("oversized.txt")
        try createSparseFile(at: oversized, size: UInt64(Constants.Attachments.maxFileSizeBytes + 1))
        await #expect(throws: DocumentProcessingService.ProcessingError.self) {
            _ = try await DocumentProcessingService.shared.extractText(from: oversized)
        }
    }

    @Test("Project conversion rejects oversized input before client setup")
    func conversionRejectsOversizedInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("oversized.docx")
        let size = Constants.Attachments.maxFileSizeBytes + 1
        try createSparseFile(at: oversized, size: UInt64(size))

        await #expect(throws: BoundedFileIO.Error.fileTooLarge(
            size: size,
            maximum: Constants.Attachments.maxFileSizeBytes
        )) {
            _ = try await DocumentConversionService.shared.convertToMarkdown(
                url: oversized,
                filename: "oversized.docx"
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func createSparseFile(at url: URL, size: UInt64) throws {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: size)
        handle.closeFile()
    }
}
