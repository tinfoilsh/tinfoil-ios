import Foundation
import Testing
@testable import TinfoilChat

/// Reversible byte transform standing in for AES-GCM so tests can verify the
/// cache never writes the project list to disk as-is.
private struct XorEncryptor: ChatEncryptor {
    let key: UInt8 = 0x5A

    func encryptData(_ data: Data) async throws -> EncryptedData {
        EncryptedData(iv: "test", data: Data(data.map { $0 ^ key }).base64EncodedString())
    }

    func decryptData(_ encrypted: EncryptedData) async throws -> Data {
        guard let raw = Data(base64Encoded: encrypted.data) else { throw CocoaError(.coderInvalidValue) }
        return Data(raw.map { $0 ^ key })
    }
}

struct ProjectListCacheTests {
    private let userId = "cache-test-\(UUID().uuidString)"

    private func makeProject(_ id: String, name: String, decryptionFailed: Bool? = nil) -> Project {
        Project(
            id: id,
            name: name,
            color: nil,
            description: "",
            systemInstructions: "",
            memory: [],
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            syncVersion: 1,
            decryptionFailed: decryptionFailed
        )
    }

    @Test func roundTripsProjectsThroughEncryptor() async {
        let cache = ProjectListCache(encryptor: XorEncryptor())
        defer { Task { await cache.clear(userId: userId) } }
        let projects = [makeProject("a", name: "Alpha"), makeProject("b", name: "Beta")]

        await cache.save(projects, userId: userId)
        let restored = await cache.load(userId: userId)

        #expect(restored == projects)
    }

    @Test func dropsUndecryptablePlaceholders() async {
        let cache = ProjectListCache(encryptor: XorEncryptor())
        defer { Task { await cache.clear(userId: userId) } }

        await cache.save(
            [makeProject("a", name: "Alpha"), makeProject("b", name: "Encrypted", decryptionFailed: true)],
            userId: userId
        )
        let restored = await cache.load(userId: userId)

        #expect(restored.map(\.id) == ["a"])
    }

    @Test func clearRemovesTheCachedList() async {
        let cache = ProjectListCache(encryptor: XorEncryptor())
        await cache.save([makeProject("a", name: "Alpha")], userId: userId)

        await cache.clear(userId: userId)

        #expect(await cache.load(userId: userId).isEmpty)
    }

    @Test func unreadableCacheIsDiscardedInsteadOfFailing() async {
        let writer = ProjectListCache(encryptor: XorEncryptor())
        defer { Task { await writer.clear(userId: userId) } }
        await writer.save([makeProject("a", name: "Alpha")], userId: userId)

        // A reader with a different key cannot decode the envelope contents.
        struct OtherKey: ChatEncryptor {
            func encryptData(_ data: Data) async throws -> EncryptedData { EncryptedData(iv: "x", data: data.base64EncodedString()) }
            func decryptData(_ encrypted: EncryptedData) async throws -> Data { Data(base64Encoded: encrypted.data) ?? Data() }
        }
        let reader = ProjectListCache(encryptor: OtherKey())

        #expect(await reader.load(userId: userId).isEmpty)
        #expect(await writer.load(userId: userId).isEmpty)
    }
}
