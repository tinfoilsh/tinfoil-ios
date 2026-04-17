import Testing
import Foundation
@testable import TinfoilChat

@Suite("Citation Regex Tests")
struct CitationRegexTests {

    // MARK: - stripCitations: complete citations

    @Test("Strips a single complete citation")
    func stripSingleCitation() {
        let input = "Some text [1](#cite-1~https://example.com~Example%20Title) more text"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "Some text more text")
    }

    @Test("Strips citation with leading space")
    func stripCitationWithLeadingSpace() {
        let input = "word [2](#cite-2~https://example.com~Title) end"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "word end")
    }

    @Test("Strips multiple citations")
    func stripMultipleCitations() {
        let input = "First [1](#cite-1~https://a.com~A) and second [2](#cite-2~https://b.com~B) done"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "First and second done")
    }

    @Test("Strips adjacent citations")
    func stripAdjacentCitations() {
        let input = "text [1](#cite-1~https://a.com~A) [2](#cite-2~https://b.com~B) end"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "text end")
    }

    @Test("Strips citation at start of string")
    func stripCitationAtStart() {
        let input = "[1](#cite-1~https://example.com~Title) rest of text"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == " rest of text" || result == "rest of text")
    }

    @Test("Strips citation at end of string")
    func stripCitationAtEnd() {
        let input = "some text [1](#cite-1~https://example.com~Title)"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "some text")
    }

    @Test("Strips citation with parentheses in URL")
    func stripCitationWithParensInURL() {
        let input = "text [1](#cite-1~https://en.wikipedia.org/wiki/Thing_(concept)~Title) end"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "text end")
    }

    @Test("Strips citation with encoded special characters")
    func stripCitationWithEncodedChars() {
        let input = "text [1](#cite-1~https://example.com/path%28a%29~Title%20Here) end"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == "text end")
    }

    // MARK: - stripCitations: no-op cases

    @Test("Returns empty string unchanged")
    func emptyString() {
        let result = LaTeXMarkdownView.stripCitations(from: "")
        #expect(result == "")
    }

    @Test("Returns text without citations unchanged")
    func noCitations() {
        let input = "Just regular text with [links](https://example.com) and stuff"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == input)
    }

    @Test("Does not strip regular markdown links")
    func preservesRegularLinks() {
        let input = "See [this page](https://example.com) for details"
        let result = LaTeXMarkdownView.stripCitations(from: input)
        #expect(result == input)
    }

    // MARK: - stripCitations: catastrophic backtracking regression

    /// Runs stripCitations and fails if it takes longer than the given timeout.
    private func assertStripCitationsCompletesQuickly(_ input: String, timeoutMs: Int = 500, sourceLocation: SourceLocation = #_sourceLocation) async {
        let capturedInput = input
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                LaTeXMarkdownView.stripCitations(from: capturedInput)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        guard let result else {
            Issue.record("stripCitations did not complete within \(timeoutMs)ms — likely catastrophic backtracking", sourceLocation: sourceLocation)
            return
        }
        #expect(result == input, "Incomplete citation should not be stripped", sourceLocation: sourceLocation)
    }

    @Test("Partial citation with no closing paren completes quickly")
    func partialCitationNoClosingParen() async {
        // Exact crash scenario: streaming delivers a citation with opening paren but no close
        let input = "iOS's version [1](#cite-1~https://github.com/ds4sd/docling/blob/main/docling/pipeline_options.py"
        await assertStripCitationsCompletesQuickly(input)
    }

    @Test("Partial citation with long URL and no closing paren completes quickly")
    func partialCitationLongURLNoClosingParen() async {
        let longPath = String(repeating: "/segment", count: 50)
        let input = "text [1](#cite-1~https://example.com\(longPath)"
        await assertStripCitationsCompletesQuickly(input)
    }

    @Test("Partial citation with nested open parens and no closing paren completes quickly")
    func partialCitationNestedOpenParens() async {
        // Multiple open parens without matching closes — worst case for backtracking
        let input = "text [1](#cite-1~https://url.com/a(b(c(d(e"
        await assertStripCitationsCompletesQuickly(input)
    }

    @Test("Partial citation mid-stream with trailing content completes quickly")
    func partialCitationMidStream() async {
        // Simulates the exact crash from the Sentry report
        let input = "The \"Apple Vision\" option in Docling specifically uses macOS's Vision framework via Python bindings (PyObjC), not iOS's version[1](#cite-1~https://github.com/ds4sd/docling/blob/main/docling/pipeline_options.py"
        await assertStripCitationsCompletesQuickly(input)
    }

    @Test("Repeated partial citations do not cause cumulative slowdown")
    func repeatedPartialCitations() async {
        // Simulates many streaming re-renders with growing content
        var content = ""
        for i in 1...20 {
            content += "Paragraph \(i) with a citation [\(i)](#cite-\(i)~https://example.com/very/long/path/to/resource"
            await assertStripCitationsCompletesQuickly(content)
        }
    }

    // MARK: - rewriteAnnotatedLinks: markdown citation links from the new backend format

    @Test("Rewrites annotated link text to the host domain")
    func rewriteAnnotatedLinkToDomain() {
        let input = "See [some title](https://example.com/page) for details"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(
            in: input,
            citationUrls: ["https://example.com/page"]
        )
        #expect(result == "See [example.com](https://example.com/page) for details")
    }

    @Test("Strips www. prefix from the host domain")
    func rewriteAnnotatedLinkStripsWWW() {
        let input = "[title](https://www.example.com/path)"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(
            in: input,
            citationUrls: ["https://www.example.com/path"]
        )
        #expect(result == "[example.com](https://www.example.com/path)")
    }

    @Test("Leaves non-annotated links unchanged")
    func rewriteLeavesNonAnnotatedLinks() {
        let input = "See [this article](https://unrelated.com) and [another](https://example.com/page)"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(
            in: input,
            citationUrls: ["https://example.com/page"]
        )
        #expect(result == "See [this article](https://unrelated.com) and [example.com](https://example.com/page)")
    }

    @Test("Rewrites multiple annotated links in one pass")
    func rewriteMultipleAnnotatedLinks() {
        let input = "[a](https://one.com) and [b](https://two.org/path)"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(
            in: input,
            citationUrls: ["https://one.com", "https://two.org/path"]
        )
        #expect(result == "[one.com](https://one.com) and [two.org](https://two.org/path)")
    }

    @Test("Returns input unchanged when citation set is nil")
    func rewriteNilCitationsNoOp() {
        let input = "See [some title](https://example.com/page) for details"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(in: input, citationUrls: nil)
        #expect(result == input)
    }

    @Test("Returns input unchanged when citation set is empty")
    func rewriteEmptyCitationsNoOp() {
        let input = "See [some title](https://example.com/page) for details"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(in: input, citationUrls: [])
        #expect(result == input)
    }

    @Test("Handles parentheses inside annotated URL")
    func rewriteAnnotatedLinkWithParensInURL() {
        let input = "[title](https://en.wikipedia.org/wiki/Foo_(bar))"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(
            in: input,
            citationUrls: ["https://en.wikipedia.org/wiki/Foo_(bar)"]
        )
        #expect(result == "[en.wikipedia.org](https://en.wikipedia.org/wiki/Foo_(bar))")
    }

    @Test("Leaves legacy #cite- style links to stripCitations")
    func rewriteLeavesLegacyCiteLinks() {
        let input = "text [1](#cite-1~https://example.com~Title) end"
        let result = LaTeXMarkdownView.rewriteAnnotatedLinks(
            in: input,
            citationUrls: ["https://example.com"]
        )
        // The href starts with `#cite-`, not the annotated URL, so this helper
        // leaves it untouched; stripCitations handles the legacy format.
        #expect(result == input)
    }
}
