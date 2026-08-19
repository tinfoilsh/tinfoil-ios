import Foundation
import Testing
@testable import TinfoilChat

@Suite("Managed File Store Tests")
struct ManagedFileStoreTests {
    @Test("Stages owned files without deleting providers")
    func stagesOwnedFilesWithoutDeletingProviders() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let providerURL = fixture.rootURL.appendingPathComponent("provider.txt")
        try Data("provider data".utf8).write(to: providerURL)

        let file = try fixture.store.stage(sourceURL: providerURL, maximumSize: 1_024)

        #expect(fixture.store.owns(file.url))
        #expect(FileManager.default.fileExists(atPath: providerURL.path))
        file.discard()
        file.discard()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(FileManager.default.fileExists(atPath: providerURL.path))
    }

    @Test("Rejects oversized and symbolic link sources")
    func rejectsOversizedAndSymbolicLinkSources() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourceURL = fixture.rootURL.appendingPathComponent("source.txt")
        let linkURL = fixture.rootURL.appendingPathComponent("link.txt")
        try Data(repeating: 1, count: 32).write(to: sourceURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)

        #expect(throws: BoundedFileIOError.self) {
            try fixture.store.stage(sourceURL: sourceURL, maximumSize: 8)
        }
        #expect(throws: BoundedFileIOError.self) {
            try fixture.store.stage(sourceURL: linkURL, maximumSize: 1_024)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: linkURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingURL.path).isEmpty)
    }

    @Test("Stops incremental I/O when a source grows beyond the limit")
    func stopsIncrementalIOWhenSourceGrowsBeyondLimit() throws {
        var chunks = [Data(repeating: 1, count: 4), Data(repeating: 2, count: 5)]
        var consumed = Data()

        #expect(throws: BoundedFileIOError.self) {
            try BoundedFileIO.stream(maximumSize: 8) { _ in
                chunks.isEmpty ? nil : chunks.removeFirst()
            } consume: { chunk in
                consumed.append(chunk)
            }
        }

        #expect(consumed == Data(repeating: 1, count: 4))
    }

    @Test("Startup sweep removes every file in the managed root")
    func startupSweepRemovesEveryManagedFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let file = try fixture.store.stage(
            data: Data("staged".utf8),
            fileExtension: "txt",
            maximumSize: 1_024
        )
        let unrelatedURL = fixture.stagingURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelatedURL)

        try fixture.store.sweepOnStartup()

        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @Test("Staged files use protection and backup exclusion")
    func stagedFilesUseProtectionAndBackupExclusion() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let file = try fixture.store.stage(
            data: Data("protected".utf8),
            fileExtension: "txt",
            maximumSize: 1_024
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let values = try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey])

        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #expect(values.isExcludedFromBackup == true)
    }

    private func makeFixture() throws -> (
        store: ManagedFileStore,
        rootURL: URL,
        stagingURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent("ManagedFileStaging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        return (
            ManagedFileStore(rootURL: stagingURL),
            rootURL,
            stagingURL
        )
    }
}
