import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TinfoilChat

@Suite("Shared Import Store Tests")
struct SharedImportStoreTests {
    @Test("Classifies supported images and documents")
    func classifiesSupportedTypes() {
        #expect(
            SharedImportClassifier.kind(
                typeIdentifier: UTType.png.identifier,
                fileName: "photo.png"
            ) == .image
        )
        #expect(
            SharedImportClassifier.kind(
                typeIdentifier: UTType.pdf.identifier,
                fileName: "document.pdf"
            ) == .document
        )
        #expect(
            SharedImportClassifier.kind(
                typeIdentifier: UTType.movie.identifier,
                fileName: "video.pdf"
            ) == nil
        )
    }

    @Test("Persists and removes a shared attachment")
    func persistsAndRemovesSharedAttachment() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let sourceURL = fixture.rootURL.appendingPathComponent("source.pdf")
        let sourceData = Data("%PDF-1.7 shared document".utf8)
        try sourceData.write(to: sourceURL)

        let request = try fixture.store.enqueue(
            sourceURL: sourceURL,
            typeIdentifier: UTType.pdf.identifier,
            originalFileName: "../../Quarterly Report?.pdf"
        )

        #expect(request.item.originalFileName == "Quarterly Report_.pdf")
        #expect(fixture.store.pendingRequests() == [request])
        #expect(try Data(contentsOf: fixture.store.payloadURL(for: request)) == sourceData)

        fixture.store.removeRequest(id: request.id)
        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Keeps the extension when truncating an overlong file name")
    func keepsExtensionWhenTruncating() {
        let longStem = String(repeating: "a", count: 300)
        let sanitized = SharedImportStore.sanitizedFileName("\(longStem).pdf")

        #expect(sanitized.count <= SharedImportConfiguration.maximumFileNameLength)
        #expect(sanitized.hasSuffix(".pdf"))
    }

    @Test("Ignores requests with corrupted manifests")
    func ignoresCorruptedManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let sourceURL = fixture.rootURL.appendingPathComponent("source.txt")
        try Data("Shared text".utf8).write(to: sourceURL)

        let request = try fixture.store.enqueue(
            sourceURL: sourceURL,
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "Notes.txt"
        )
        let manifestURL = fixture.inboxURL
            .appendingPathComponent(request.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(SharedImportConfiguration.manifestFileName)
        try Data("invalid".utf8).write(to: manifestURL)

        #expect(fixture.store.pendingRequests().isEmpty)
    }

    private func makeFixture() throws -> (
        store: SharedImportStore,
        rootURL: URL,
        inboxURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return (
            try SharedImportStore(inboxURL: inboxURL),
            rootURL,
            inboxURL
        )
    }
}
