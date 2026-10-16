import Foundation
import Testing
import WebKit
@testable import TinfoilChat

@Suite("Artifact HTML Sandbox Tests")
struct ArtifactHTMLViewTests {
    @Test("Allows the artifact document and jumps to its anchors")
    func allowsArtifactDocument() throws {
        let base = Constants.Artifacts.baseURL
        let anchor = try #require(URL(string: "#exercise-3", relativeTo: base)?.absoluteURL)

        #expect(ArtifactNavigation.isArtifactDocument(base))
        #expect(ArtifactNavigation.isArtifactDocument(anchor))
    }

    @Test("Rejects every other page, including other paths on the artifact origin")
    func rejectsOtherDocuments() throws {
        let others = [
            "https://example.com/",
            "https://artifact.invalid/exercise.html",
            "https://artifact.invalid/?entry=1",
            "http://artifact.invalid/",
            "about:blank",
        ]
        for string in others {
            let url = try #require(URL(string: string))
            #expect(!ArtifactNavigation.isArtifactDocument(url), "\(string)")
        }
    }

    @Test("Allows only frames whose document is inline")
    func allowsOnlyInlineFrames() throws {
        #expect(ArtifactNavigation.isInlineFrameDocument(try #require(URL(string: "about:srcdoc"))))
        #expect(ArtifactNavigation.isInlineFrameDocument(try #require(URL(string: "data:text/html,hello"))))
        #expect(!ArtifactNavigation.isInlineFrameDocument(try #require(URL(string: "https://example.com/embed"))))
    }

    @Test("WebKit accepts the content rules, so the preview can load")
    @MainActor
    func contentRulesCompile() async throws {
        _ = try await ArtifactContentRules.compiled()
    }
}
