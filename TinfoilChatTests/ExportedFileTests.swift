import Foundation
import Testing
@testable import TinfoilChat

@Suite("Exported file")
struct ExportedFileTests {
    private static func exportsDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportedFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writesEachFileUnderItsNameInADirectoryOfItsOwn() throws {
        let exports = Self.exportsDirectory()
        defer { try? FileManager.default.removeItem(at: exports) }
        let data = Data([1, 2, 3])

        let first = try ExportedFile.write(data, named: "Report (final).pdf", in: exports)
        let second = try ExportedFile.write(data, named: "Report (final).pdf", in: exports)

        #expect(first.url.lastPathComponent == "Report (final).pdf")
        #expect(try Data(contentsOf: first.url) == data)
        #expect(first.url.deletingLastPathComponent() != second.url.deletingLastPathComponent())

        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))

        try ExportedFile.removeAll(in: exports)
        #expect(!FileManager.default.fileExists(atPath: exports.path))
        try ExportedFile.removeAll(in: exports)
    }

    @Test func aNameCannotPlaceItsFileOutsideItsDirectory() throws {
        #expect(ExportedFile.fileName("../../secrets.txt") == "secrets.txt")
        #expect(ExportedFile.fileName("folder/notes.md") == "notes.md")
        for name in ["", ".", "..", "/", "folder/.."] {
            #expect(ExportedFile.fileName(name) == "Untitled")
        }

        let exports = Self.exportsDirectory()
        defer { try? FileManager.default.removeItem(at: exports) }
        let file = try ExportedFile.write(Data([1]), named: "../escaped.txt", in: exports)
        #expect(file.url.lastPathComponent == "escaped.txt")
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == exports.standardizedFileURL)
    }
}
