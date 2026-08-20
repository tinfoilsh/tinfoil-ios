import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TinfoilChat

private final class SharedImportCoordinationState: @unchecked Sendable {
    private let lock = NSLock()
    private var publicationReleased = false
    private var purgeEnteredBeforeRelease = false

    func releasePublication() {
        lock.lock()
        publicationReleased = true
        lock.unlock()
    }

    func recordPurgeEntry() {
        lock.lock()
        purgeEnteredBeforeRelease = purgeEnteredBeforeRelease || !publicationReleased
        lock.unlock()
    }

    var didSerializePurgeAfterPublication: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !purgeEnteredBeforeRelease
    }
}

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

        try fixture.store.removeRequest(id: request.id)
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

    @Test("Enqueues payload data without an intermediary file")
    func enqueuesPayloadDataDirectly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let payload = Data("Direct shared text".utf8)

        let request = try fixture.store.enqueue(
            data: payload,
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "Notes.txt"
        )

        #expect(try fixture.store.payloadData(for: request) == payload)
    }

    @Test("Removes stale corrupt requests after 24 hours")
    func removesStaleCorruptRequests() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let requestDirectory = fixture.inboxURL.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: false)
        try Data("invalid".utf8).write(
            to: requestDirectory.appendingPathComponent(SharedImportConfiguration.manifestFileName)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: requestDirectory.path
        )

        _ = fixture.store.pendingRequests()

        #expect(!FileManager.default.fileExists(atPath: requestDirectory.path))
    }

    @Test("Retains valid requests for 30 days")
    func retainsValidRequestsForThirtyDays() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let request = try fixture.store.enqueue(
            data: Data("Shared text".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "Notes.txt"
        )
        let manifestURL = fixture.inboxURL
            .appendingPathComponent(request.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(SharedImportConfiguration.manifestFileName)
        let retainedRequest = SharedImportRequest(
            id: request.id,
            createdAt: Date().addingTimeInterval(-29 * 24 * 60 * 60),
            item: request.item
        )
        try JSONEncoder().encode(retainedRequest).write(to: manifestURL, options: .atomic)

        #expect(fixture.store.pendingRequests() == [retainedRequest])

        let expiredRequest = SharedImportRequest(
            id: request.id,
            createdAt: Date().addingTimeInterval(-31 * 24 * 60 * 60),
            item: request.item
        )
        try JSONEncoder().encode(expiredRequest).write(to: manifestURL, options: .atomic)

        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Purge waits for publication and removes its request")
    func purgeCoordinatesWithPublication() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let publicationBegan = DispatchSemaphore(value: 0)
        let allowPublication = DispatchSemaphore(value: 0)
        let purgeAttempted = DispatchSemaphore(value: 0)
        let coordinationState = SharedImportCoordinationState()
        let publicationStore = try SharedImportStore(
            inboxURL: inboxURL,
            publicationDidBegin: {
                publicationBegan.signal()
                allowPublication.wait()
                coordinationState.releasePublication()
            }
        )
        let purgeStore = try SharedImportStore(
            inboxURL: inboxURL,
            purgeDidBegin: coordinationState.recordPurgeEntry
        )

        let publication = Task.detached {
            _ = try publicationStore.enqueue(
                data: Data("Shared text".utf8),
                typeIdentifier: UTType.plainText.identifier,
                originalFileName: "Notes.txt"
            )
        }
        publicationBegan.wait()
        let purge = Task.detached {
            purgeAttempted.signal()
            try purgeStore.purgeAllRequests()
        }

        purgeAttempted.wait()
        allowPublication.signal()
        try await publication.value
        try await purge.value

        #expect(coordinationState.didSerializePurgeAfterPublication)
        #expect(purgeStore.pendingRequests().isEmpty)
    }

    @Test("Purge blocks publication until the next account is ready")
    func purgeFencesPublication() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try fixture.store.purgeAllRequests()

        #expect(throws: SharedImportError.self) {
            try fixture.store.enqueue(
                data: Data("Shared text".utf8),
                typeIdentifier: UTType.plainText.identifier,
                originalFileName: "Notes.txt"
            )
        }

        try fixture.store.allowPublications()
        let request = try fixture.store.enqueue(
            data: Data("Shared text".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "Notes.txt"
        )
        #expect(fixture.store.pendingRequests() == [request])
    }

    @Test("Passive publication pause preserves pending imports")
    func publicationPausePreservesPendingImports() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let request = try fixture.store.enqueue(
            data: Data("Shared text".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "Notes.txt"
        )

        try fixture.store.blockPublications()

        #expect(fixture.store.pendingRequests() == [request])
        #expect(throws: SharedImportError.self) {
            try fixture.store.enqueue(
                data: Data("New text".utf8),
                typeIdentifier: UTType.plainText.identifier,
                originalFileName: "New Notes.txt"
            )
        }

        try fixture.store.allowPublications()
        #expect(fixture.store.pendingRequests() == [request])
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
