import Foundation
import Testing
@testable import TinfoilChat

@Suite("Encryption key file")
struct EncryptionKeyFileTests {
    @Test func writesEachKeyFileInADirectoryOfItsOwn() throws {
        let exports = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptionKeyFileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: exports) }
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12)))

        let first = try EncryptionKeyFile.write(key: "key_abc123", date: date, exportsDirectory: exports)
        let second = try EncryptionKeyFile.write(key: "key_abc123", date: date, exportsDirectory: exports)

        #expect(first.lastPathComponent == "tinfoil-chat-key-2026-10-28.pem")
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        #expect(first.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == exports.standardizedFileURL)
        #expect(try String(contentsOf: first, encoding: .utf8)
            == "-----BEGIN TINFOIL CHAT ENCRYPTION KEY-----\nabc123\n-----END TINFOIL CHAT ENCRYPTION KEY-----")

        EncryptionKeyFile.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        try EncryptionKeyFile.removeExports(in: exports)
        #expect(!FileManager.default.fileExists(atPath: exports.path))
        try EncryptionKeyFile.removeExports(in: exports)
    }
}
