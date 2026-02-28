import Testing
import Foundation
@testable import TinfoilChat

@Suite("StreamingMarkdownChunker Tests")
struct StreamingMarkdownChunkerTests {

    /// Feed a string to the chunker one token at a time (split by newlines to simulate streaming)
    private func feedLines(_ text: String, to chunker: StreamingMarkdownChunker) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            chunker.appendToken(line)
            if i < lines.count - 1 {
                chunker.appendToken("\n")
            }
        }
    }

    // MARK: - Paragraph chunking

    @Test("Single paragraph in working buffer before finalize")
    func singleParagraphWorkingBuffer() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("Hello world")

        let chunks = chunker.getAllChunks()
        #expect(chunks.count == 1)
        #expect(chunks[0].content == "Hello world")
        #expect(chunks[0].isComplete == false)
    }

    @Test("Double newline finalizes a paragraph chunk")
    func doubleNewlineFinalizesParagraph() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("First paragraph")
        chunker.appendToken("\n\n")

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 1)
        #expect(completed[0].content == "First paragraph")
        #expect(completed[0].type == .paragraph)
    }

    @Test("Multiple paragraphs separated by double newlines")
    func multipleParagraphs() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("First")
        chunker.appendToken("\n\n")
        chunker.appendToken("Second")
        chunker.appendToken("\n\n")

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 2)
        #expect(completed[0].content == "First")
        #expect(completed[1].content.trimmingCharacters(in: .whitespacesAndNewlines) == "Second")
    }

    @Test("Token-by-token streaming produces correct result")
    func tokenByTokenStreaming() {
        let chunker = StreamingMarkdownChunker()
        for char in "Hello world\n\n" {
            chunker.appendToken(String(char))
        }

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 1)
        #expect(completed[0].content == "Hello world")
    }

    // MARK: - Code block detection

    @Test("Detects code block opening")
    func detectsCodeBlockOpening() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("```")
        chunker.appendToken("\n")
        chunker.appendToken("let x = 1")

        let chunks = chunker.getAllChunks()
        #expect(chunks.count == 1)
        #expect(chunks[0].isComplete == false)
        #expect(chunks[0].content.contains("```"))
    }

    @Test("Finalizes code block on closing fence")
    func finalizesCodeBlock() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("```")
        chunker.appendToken("\n")
        chunker.appendToken("let x = 1")
        chunker.appendToken("\n")
        chunker.appendToken("```")

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 1)
        #expect(completed[0].type == .codeBlock(language: nil))
    }

    @Test("Extracts code block language")
    func extractsCodeBlockLanguage() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("```swift")
        chunker.appendToken("\n")
        chunker.appendToken("let x = 1")
        chunker.appendToken("\n")
        chunker.appendToken("```")

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 1)
        #expect(completed[0].type == .codeBlock(language: "swift"))
    }

    @Test("Text before code block becomes separate paragraph")
    func textBeforeCodeBlock() {
        let chunker = StreamingMarkdownChunker()
        feedLines("Some text\n```\ncode\n```", to: chunker)

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 2)
        #expect(completed[0].type == .paragraph)
        #expect(completed[0].content.contains("Some text"))
        #expect(completed[1].type == .codeBlock(language: nil))
    }

    // MARK: - Table detection

    @Test("Detects markdown table")
    func detectsTable() {
        let chunker = StreamingMarkdownChunker()
        feedLines("| A | B |\n| --- | --- |\n| 1 | 2 |", to: chunker)
        chunker.appendToken("\n\n")

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 1)
        #expect(completed[0].type == .table)
    }

    // MARK: - Finalize

    @Test("Finalize completes working buffer as paragraph")
    func finalizeCompletesParagraph() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("Incomplete text")
        chunker.finalize()

        let chunks = chunker.getAllChunks()
        #expect(chunks.count == 1)
        #expect(chunks[0].isComplete == true)
        #expect(chunks[0].type == .paragraph)
        #expect(chunks[0].content == "Incomplete text")
    }

    @Test("Finalize completes an open code block")
    func finalizeCompletesCodeBlock() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("```python")
        chunker.appendToken("\n")
        chunker.appendToken("print('hello')")
        chunker.finalize()

        let chunks = chunker.getAllChunks()
        #expect(chunks.count == 1)
        #expect(chunks[0].isComplete == true)
        #expect(chunks[0].type == .codeBlock(language: "python"))
    }

    @Test("Finalize completes an open table")
    func finalizeCompletesTable() {
        let chunker = StreamingMarkdownChunker()
        feedLines("| A | B |\n| --- | --- |\n| 1 | 2 |", to: chunker)
        chunker.finalize()

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count == 1)
        #expect(completed[0].type == .table)
    }

    // MARK: - Reset

    @Test("Reset clears all state")
    func resetClearsState() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("Some content")
        chunker.appendToken("\n\n")
        chunker.appendToken("More content")
        chunker.reset()

        let chunks = chunker.getAllChunks()
        #expect(chunks.isEmpty)
    }

    // MARK: - Mixed content

    @Test("Handles paragraph then code block then paragraph")
    func mixedContent() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("Intro text")
        chunker.appendToken("\n\n")
        feedLines("```js\nconsole.log('hi')\n```", to: chunker)
        chunker.appendToken("\n\n")
        chunker.appendToken("Closing text")
        chunker.finalize()

        let chunks = chunker.getAllChunks()
        let completed = chunks.filter { $0.isComplete }
        #expect(completed.count >= 3)

        let types = completed.map { $0.type }
        #expect(types.contains(.paragraph))
        #expect(types.contains(where: { if case .codeBlock = $0 { return true }; return false }))
    }

    // MARK: - getAllChunks includes working buffer

    @Test("getAllChunks includes incomplete working buffer")
    func getAllChunksIncludesWorkingBuffer() {
        let chunker = StreamingMarkdownChunker()
        chunker.appendToken("Complete")
        chunker.appendToken("\n\n")
        chunker.appendToken("Still typing...")

        let chunks = chunker.getAllChunks()
        #expect(chunks.count == 2)

        let complete = chunks.filter { $0.isComplete }
        let incomplete = chunks.filter { !$0.isComplete }
        #expect(complete.count == 1)
        #expect(incomplete.count == 1)
        #expect(incomplete[0].content.contains("Still typing..."))
    }
}
