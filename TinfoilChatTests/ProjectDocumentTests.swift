import Foundation
import Testing
@testable import TinfoilChat

@Suite("Project documents")
struct ProjectDocumentTests {
    private static func document(named filename: String, hasFile: Bool? = nil) -> ProjectDocument {
        ProjectDocument(Components.Schemas.ProjectDocument(
            id: "doc-1",
            projectId: "project-1",
            filename: filename,
            contentType: "application/pdf",
            sizeBytes: 1,
            hasFile: hasFile
        ))
    }

    @Test func aDocumentsTextIsSavedAsMarkdownUnlessItsNameNamesATextFile() {
        #expect(Self.document(named: "notes.md").textFileName == "notes.md")
        #expect(Self.document(named: "NOTES.TXT").textFileName == "NOTES.TXT")
        #expect(Self.document(named: "report.pdf").textFileName == "report.pdf.md")
        #expect(Self.document(named: "plain").textFileName == "plain.md")
        #expect(Self.document(named: "").textFileName == "Untitled.md")
    }

    @Test func aDocumentStoredBeforeFilesWereKeptHasNone() {
        #expect(!Self.document(named: "report.pdf").hasFile)
        #expect(!Self.document(named: "report.pdf", hasFile: false).hasFile)
        #expect(Self.document(named: "report.pdf", hasFile: true).hasFile)
    }
}
