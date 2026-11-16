import Foundation
import Testing
import TinfoilIcons
@testable import TinfoilChat

struct FilePreviewClassifierTests {
    @Test func thumbnailTakesPrecedenceOverText() {
        let kind = FilePreviewClassifier.kind(
            filename: "notes.txt",
            hasThumbnail: true,
            textContent: "some text"
        )
        #expect(kind == .image)
    }

    @Test func plainTextDocumentsRenderAsText() {
        #expect(FilePreviewClassifier.kind(filename: "notes.md", hasThumbnail: false, textContent: "# Title") == .text)
        #expect(FilePreviewClassifier.kind(filename: "main.swift", hasThumbnail: false, textContent: "let x = 1") == .text)
    }

    @Test func binaryOrEmptyDocumentsFallBackToIcon() {
        #expect(FilePreviewClassifier.kind(filename: "report.pdf", hasThumbnail: false, textContent: "Extracted") == .icon)
        #expect(FilePreviewClassifier.kind(filename: "notes.txt", hasThumbnail: false, textContent: "   \n") == .icon)
        #expect(FilePreviewClassifier.kind(filename: "photo.png", hasThumbnail: false, textContent: "A description") == .icon)
    }

    @Test func excerptNormalizesLineEndingsAndTruncates() {
        #expect(FilePreviewClassifier.excerpt("a\r\nb\rc") == "a\nb\nc")

        let manyLines = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let excerptLines = FilePreviewClassifier.excerpt(manyLines).split(separator: "\n")
        #expect(excerptLines.count == Constants.FilePreview.textMaxLines)

        let longLine = String(repeating: "x", count: 5_000)
        #expect(FilePreviewClassifier.excerpt(longLine).count == Constants.FilePreview.textMaxCharacters)
    }

    @Test func iconMatchesFileType() {
        #expect(FilePreviewClassifier.icon(for: "a.pdf") == .document)
        #expect(FilePreviewClassifier.icon(for: "a.CSV") == .tools)
        #expect(FilePreviewClassifier.icon(for: "a.heic") == .image)
        #expect(FilePreviewClassifier.icon(for: "a.html") == .globe)
    }
}
