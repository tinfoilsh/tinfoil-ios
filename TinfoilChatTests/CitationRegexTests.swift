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

    /// Runs stripCitations on a background thread and fails if it takes longer than the given timeout.
    private func assertStripCitationsCompletesQuickly(_ input: String, timeoutMs: Int = 500, sourceLocation: SourceLocation = #_sourceLocation) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        DispatchQueue.global().async {
            result = LaTeXMarkdownView.stripCitations(from: input)
            semaphore.signal()
        }

        let timedOut = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut
        #expect(!timedOut, "stripCitations took longer than \(timeoutMs)ms — likely catastrophic backtracking", sourceLocation: sourceLocation)
        if !timedOut {
            #expect(result == input, "Incomplete citation should not be stripped", sourceLocation: sourceLocation)
        }
    }

    @Test("Partial citation with no closing paren completes quickly")
    func partialCitationNoClosingParen() {
        // Exact crash scenario: streaming delivers a citation with opening paren but no close
        let input = "iOS's version [1](#cite-1~https://github.com/ds4sd/docling/blob/main/docling/pipeline_options.py"
        assertStripCitationsCompletesQuickly(input)
    }

    @Test("Partial citation with long URL and no closing paren completes quickly")
    func partialCitationLongURLNoClosingParen() {
        let longPath = String(repeating: "/segment", count: 50)
        let input = "text [1](#cite-1~https://example.com\(longPath)"
        assertStripCitationsCompletesQuickly(input)
    }

    @Test("Partial citation with nested open parens and no closing paren completes quickly")
    func partialCitationNestedOpenParens() {
        // Multiple open parens without matching closes — worst case for backtracking
        let input = "text [1](#cite-1~https://url.com/a(b(c(d(e"
        assertStripCitationsCompletesQuickly(input)
    }

    @Test("Partial citation mid-stream with trailing content completes quickly")
    func partialCitationMidStream() {
        // Simulates the exact crash from the Sentry report
        let input = "The \"Apple Vision\" option in Docling specifically uses macOS's Vision framework via Python bindings (PyObjC), not iOS's version[1](#cite-1~https://github.com/ds4sd/docling/blob/main/docling/pipeline_options.py"
        assertStripCitationsCompletesQuickly(input)
    }

    @Test("Repeated partial citations do not cause cumulative slowdown")
    func repeatedPartialCitations() {
        // Simulates many streaming re-renders with growing content
        var content = ""
        for i in 1...20 {
            content += "Paragraph \(i) with a citation [\(i)](#cite-\(i)~https://example.com/very/long/path/to/resource"
            assertStripCitationsCompletesQuickly(content)
        }
    }

    // MARK: - citationMarkerRegex (【1】 format used in ChatViewModel)

    @Test("Citation marker regex matches simple markers")
    func citationMarkerMatchesSimple() {
        let regex = try! NSRegularExpression(pattern: "【(\\d+)[^】]*】", options: [])
        let input = "Some text【1】more text"
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        #expect(matches.count == 1)
    }

    @Test("Citation marker regex matches multiple markers")
    func citationMarkerMatchesMultiple() {
        let regex = try! NSRegularExpression(pattern: "【(\\d+)[^】]*】", options: [])
        let input = "First【1】second【2】third【3】"
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        #expect(matches.count == 3)
    }

    @Test("Citation marker regex captures the number")
    func citationMarkerCapturesNumber() {
        let regex = try! NSRegularExpression(pattern: "【(\\d+)[^】]*】", options: [])
        let input = "text【42】end"
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        #expect(matches.count == 1)
        if let match = matches.first, let numRange = Range(match.range(at: 1), in: input) {
            #expect(String(input[numRange]) == "42")
        }
    }

    @Test("Citation marker regex ignores text without markers")
    func citationMarkerNoMatch() {
        let regex = try! NSRegularExpression(pattern: "【(\\d+)[^】]*】", options: [])
        let input = "Regular text with [1] brackets"
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        #expect(matches.count == 0)
    }
}
