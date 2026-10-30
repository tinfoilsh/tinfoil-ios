import Testing
@testable import TinfoilChat

@Suite("Thinking text chunks")
struct ThinkingTextChunkerTests {
    @Test func aStreamingThoughtsLastParagraphRedrawsAsItGrows() throws {
        let before = ThinkingTextChunker.chunk(growing: "First idea.\n\nSecond")
        let after = ThinkingTextChunker.chunk(growing: "First idea.\n\nSecond idea, longer.")
        #expect(before.first == after.first)
        let shown = try #require(before.last)
        let grown = try #require(after.last)
        #expect(grown.id == shown.id && grown.content == "Second idea, longer.")
        #expect(ThinkingChunkView(chunk: shown, isDarkMode: false) != ThinkingChunkView(chunk: grown, isDarkMode: false))
    }
}
