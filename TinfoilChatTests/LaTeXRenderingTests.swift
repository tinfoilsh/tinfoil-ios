import Testing
@testable import TinfoilChat

@MainActor
struct LaTeXRenderingTests {
    @Test func parsesMultilineDollarDisplayMath() {
        let segments = LaTeXMarkdownView.parseContent("$$\nA = b h\n$$")
        #expect(segments.count == 1)
        guard case .latex(let latex, let isDisplay) = segments.first?.kind else {
            Issue.record("Expected dollar-delimited display math")
            return
        }
        #expect(latex == "A = b h")
        #expect(isDisplay)
    }

    @Test func parsesScreenshotEquationsBeforeMarkdownUnescapesThem() {
        let segments = LaTeXMarkdownView.parseContent(#"Then \[ A = s^2 \sin\theta. \] At \(\theta = 90^\circ\) we have a square."#)
        let equations = segments.compactMap { segment -> String? in
            guard case .latex(let latex, _) = segment.kind else { return nil }
            return latex
        }
        #expect(equations == [#"A = s^2 \sin\theta."#, #"\theta = 90^\circ"#])
        guard case .latex(_, let isDisplay) = segments.dropFirst().first?.kind else {
            Issue.record("Expected display math after the opening prose")
            return
        }
        #expect(isDisplay)
    }

    @Test func leavesCodeExamplesUnchanged() {
        let source = "`\\[x\\]`\n\n```latex\n\\[y\\]\n```"
        let segments = LaTeXMarkdownView.parseContent(source)
        #expect(segments.count == 1)
        guard case .markdown(let markdown) = segments.first?.kind else {
            Issue.record("Code must remain Markdown")
            return
        }
        #expect(markdown == source)
    }

    @Test func endingStreamInvalidatesParsingEvenWithoutAnotherToken() {
        let content = #"\[A = b h\]"#
        #expect(LaTeXMarkdownView.ParsingIdentity(content: content, isStreaming: true)
            != LaTeXMarkdownView.ParsingIdentity(content: content, isStreaming: false))
    }
}
