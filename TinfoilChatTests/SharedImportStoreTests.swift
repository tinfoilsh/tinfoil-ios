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

    @Test("Persists data without an intermediate source file")
    func persistsDataRepresentation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourceData = Data("direct shared data".utf8)

        let request = try fixture.store.enqueue(
            data: sourceData,
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "Notes.txt"
        )

        #expect(request.item.byteCount == Int64(sourceData.count))
        #expect(try fixture.store.payloadData(for: request) == sourceData)
    }

    @Test("Rejects new shares at the pending request limit")
    func enforcesPendingRequestLimit() throws {
        let fixture = try makeFixture(
            maximumPendingRequestCount: 2,
            maximumPendingPayloadBytes: 100
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        for name in ["first.txt", "second.txt"] {
            _ = try fixture.store.enqueue(
                data: Data(name.utf8),
                typeIdentifier: UTType.plainText.identifier,
                originalFileName: name
            )
        }

        #expect(throws: SharedImportError.tooManyPendingRequests(maximum: 2)) {
            _ = try fixture.store.enqueue(
                data: Data("third".utf8),
                typeIdentifier: UTType.plainText.identifier,
                originalFileName: "third.txt"
            )
        }
        #expect(fixture.store.pendingRequests().count == 2)
    }

    @Test("Rejects new shares above the aggregate payload quota")
    func enforcesPendingPayloadQuota() throws {
        let fixture = try makeFixture(
            maximumPendingRequestCount: 10,
            maximumPendingPayloadBytes: 5
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        _ = try fixture.store.enqueue(
            data: Data("12345".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "full.txt"
        )

        #expect(throws: SharedImportError.pendingPayloadQuotaExceeded(maximumBytes: 5)) {
            _ = try fixture.store.enqueue(
                data: Data("6".utf8),
                typeIdentifier: UTType.plainText.identifier,
                originalFileName: "extra.txt"
            )
        }
        #expect(fixture.store.pendingRequests().count == 1)
    }

    @Test("Serializes concurrent aggregate quota checks")
    func serializesConcurrentEnqueue() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent("ShareInbox", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var results: [ConcurrentEnqueueResult] = []
        await withTaskGroup(of: ConcurrentEnqueueResult.self) { group in
            for name in ["first.txt", "second.txt"] {
                group.addTask {
                    do {
                        let store = try SharedImportStore(
                            inboxURL: inboxURL,
                            maximumPendingRequestCount: 10,
                            maximumPendingPayloadBytes: 1
                        )
                        _ = try store.enqueue(
                            data: Data("1".utf8),
                            typeIdentifier: UTType.plainText.identifier,
                            originalFileName: name
                        )
                        return .success
                    } catch SharedImportError.pendingPayloadQuotaExceeded(let maximumBytes) {
                        return maximumBytes == 1 ? .quotaRejected : .unexpectedFailure
                    } catch {
                        return .unexpectedFailure
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        #expect(results.filter { $0 == .success }.count == 1)
        #expect(results.filter { $0 == .quotaRejected }.count == 1)
        let store = try SharedImportStore(inboxURL: inboxURL)
        #expect(store.pendingRequests().count == 1)
    }

    @Test("Prefers files before immediately bounding materialized fallback data")
    func boundsMaterializedDataFallback() throws {
        let fixture = try makeFixture(
            maximumPendingRequestCount: 10,
            maximumPendingPayloadBytes: 3
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var callOrder: [String] = []
        var observedError: SharedImportError?

        SharedImportRepresentationLoader.load(
            fileRepresentation: { completion in
                callOrder.append("file")
                completion(nil, CocoaError(.fileReadUnknown))
            },
            dataRepresentation: { completion in
                callOrder.append("data")
                completion(Data("1234".utf8), nil)
            }
        ) { result in
            guard case .success(.data(let data)) = result else {
                observedError = .invalidFile
                return
            }
            do {
                _ = try fixture.store.enqueue(
                    data: data,
                    typeIdentifier: UTType.plainText.identifier,
                    originalFileName: "fallback.txt"
                )
            } catch let error as SharedImportError {
                observedError = error
            } catch {
                observedError = .invalidFile
            }
        }

        #expect(callOrder == ["file", "data"])
        #expect(observedError == .pendingPayloadQuotaExceeded(maximumBytes: 3))
        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Rejects oversized file representations before publishing")
    func rejectsOversizedFileRepresentation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourceURL = fixture.rootURL.appendingPathComponent("oversized.pdf")
        #expect(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: UInt64(SharedImportConfiguration.maximumDocumentSizeBytes + 1))
        try handle.close()

        #expect(throws: SharedImportError.self) {
            _ = try fixture.store.enqueue(
                sourceURL: sourceURL,
                typeIdentifier: UTType.pdf.identifier,
                originalFileName: "oversized.pdf"
            )
        }
        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Keeps the extension when truncating an overlong file name")
    func keepsExtensionWhenTruncating() {
        let longStem = String(repeating: "a", count: 300)
        let sanitized = SharedImportStore.sanitizedFileName("\(longStem).pdf")

        #expect(sanitized.count <= SharedImportConfiguration.maximumFileNameLength)
        #expect(sanitized.hasSuffix(".pdf"))
    }

    @Test("Removes malformed request directories only after the stale interval")
    func removesStaleMalformedRequest() throws {
        var now = Date()
        let fixture = try makeFixture(currentDate: { now })
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
        try Data(
            repeating: 0x41,
            count: Int(SharedImportConfiguration.maximumManifestSizeBytes + 1)
        ).write(to: manifestURL)

        #expect(fixture.store.pendingRequests().isEmpty)
        let requestDirectory = manifestURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: requestDirectory.path))

        now.addTimeInterval(SharedImportConfiguration.staleStagingLifetimeSeconds + 1)
        #expect(fixture.store.pendingRequests().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: requestDirectory.path))
    }

    @Test("Preserves valid pending requests across the stale interval")
    func preservesValidPendingRequest() throws {
        var now = Date()
        let fixture = try makeFixture(currentDate: { now })
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let request = try fixture.store.enqueue(
            data: Data("retry me".utf8),
            typeIdentifier: UTType.plainText.identifier,
            originalFileName: "retry.txt"
        )

        now.addTimeInterval(SharedImportConfiguration.staleStagingLifetimeSeconds + 1)

        #expect(fixture.store.pendingRequests() == [request])
    }

    @Test("Bounds payload reads by their content type limit")
    func boundsPayloadReads() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let request = try fixture.store.enqueue(
            data: Data("image".utf8),
            typeIdentifier: UTType.png.identifier,
            originalFileName: "image.png"
        )
        let oversizedByteCount = SharedImportConfiguration.maximumImageSizeBytes + 1
        let payloadURL = try fixture.store.payloadURL(for: request)
        let handle = try FileHandle(forWritingTo: payloadURL)
        try handle.truncate(atOffset: UInt64(oversizedByteCount))
        try handle.close()
        let oversizedItem = SharedImportItem(
            id: request.item.id,
            kind: request.item.kind,
            typeIdentifier: request.item.typeIdentifier,
            originalFileName: request.item.originalFileName,
            stagedFileName: request.item.stagedFileName,
            byteCount: oversizedByteCount
        )
        let oversizedRequest = SharedImportRequest(
            id: request.id,
            createdAt: request.createdAt,
            item: oversizedItem
        )

        #expect(throws: BoundedFileIO.Error.fileTooLarge(
            size: oversizedByteCount,
            maximum: SharedImportConfiguration.maximumImageSizeBytes
        )) {
            _ = try fixture.store.payloadData(for: oversizedRequest)
        }
    }

    private func makeFixture(
        currentDate: @escaping () -> Date = Date.init,
        maximumPendingRequestCount: Int = SharedImportConfiguration.maximumPendingRequestCount,
        maximumPendingPayloadBytes: Int64 = SharedImportConfiguration.maximumPendingPayloadBytes
    ) throws -> (
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
            try SharedImportStore(
                inboxURL: inboxURL,
                currentDate: currentDate,
                maximumPendingRequestCount: maximumPendingRequestCount,
                maximumPendingPayloadBytes: maximumPendingPayloadBytes
            ),
            rootURL,
            inboxURL
        )
    }
}

private enum ConcurrentEnqueueResult: Equatable, Sendable {
    case success
    case quotaRejected
    case unexpectedFailure
}
