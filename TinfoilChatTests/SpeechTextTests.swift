import Foundation
import Testing
@testable import TinfoilChat

struct SpeechTextTests {
    @Test(arguments: ["<br>", "<br/>", "<br />", "<BR>"])
    func preservesHTMLLineBreakBoundaries(tag: String) throws {
        #expect(try SpeechTextProcessor.prepare("Hello\(tag)world.") == "Hello\nworld.")
    }

    @Test
    func narratesProseWithoutCodeBlocksOrCitationBadges() throws {
        let markdown = "# Hello **world**\n\nRead [this guide](https://example.com) [1](https://source.com).\n\n```js\nsecretCode()\n```\n\nUse `settings`."
        #expect(try SpeechTextProcessor.prepare(markdown) == "Hello world\nRead this guide .\nUse settings.")
        #expect(try SpeechTextProcessor.prepare("See [1] [2][source] [docs][source] for details.\n\n[1]: https://example.com\n[source]: https://example.com") == "See docs for details.")
    }

    @Test
    func preservesListsTablesMathAndUnicode() throws {
        let markdown = "- Café &amp; tea\n- 日本語\n\n| Name | Count |\n| --- | --- |\n| Apples | 3 |\n\n$x + y$"
        #expect(try SpeechTextProcessor.prepare(markdown) == "Café & tea\n日本語\nName\nCount\nApples\n3\nx + y")
    }

    @Test(arguments: [
        ("Prices range from $10 to $20.", "Prices range from $10 to $20."),
        ("Budget: $20,000 and $30,000.", "Budget: $20,000 and $30,000."),
        ("Range: $10–$20.", "Range: $10–$20."),
        ("Range: $-10 to $+20.", "Range: $-10 to $+20."),
        ("Cost $10; solve $2 + 2$.", "Cost $10; solve 2 + 2."),
        ("Use $x$ and $$y + z$$.", "Use x and y + z."),
    ])
    func distinguishesCurrencyFromMath(input: String, expected: String) throws {
        #expect(try SpeechTextProcessor.prepare(input) == expected)
    }

    @Test
    func excludesFootnotesImagesAndBareURLs() throws {
        #expect(try SpeechTextProcessor.prepare("Answer[^1]. ![picture](https://image.com) https://example.com\n\n[^1]: Citation details") == "Answer.")
        #expect(try SpeechTextProcessor.prepare("```swift\nprivateCode()\n```").isEmpty)
    }

    @Test
    func preservesURLLabelsAndInlineCodeButSkipsRawHTML() throws {
        #expect(try SpeechTextProcessor.prepare("Read [example.com](https://other.example) and `https://example.com`.") == "Read example.com and https://example.com.")
        #expect(try SpeechTextProcessor.prepare("Read <b>this</b>.\n\n<div>Skip this block.</div>\n\nAnswer.") == "Read this.\nAnswer.")
    }

    @Test(arguments: [
        ("<think>Private reasoning</think>Answer.", "Answer."),
        ("<think>Private reasoning", ""),
        ("<THINK>Private reasoning</THINK>Answer.", "Answer."),
        ("Before<think>Private<think>nested</think>still private</think> after.", "Before after."),
        ("<think>First</think><think>Second</think>Answer.", "Answer."),
    ])
    func neverNarratesLegacyReasoning(input: String, expected: String) throws {
        #expect(try SpeechTextProcessor.prepare(input) == expected)
    }

    @Test
    func preservesLiteralClosingTagsWithoutExposingLaterReasoning() throws {
        #expect(SpeechTextProcessor.removingReasoning("Literal </think>. <think>Private</think>Answer.") == "Literal </think>. Answer.")
        #expect(SpeechTextProcessor.removingReasoning("</think><think>Unclosed private reasoning") == "</think>")
        #expect(try SpeechTextProcessor.prepare("Use `</think>` to close the tag.") == "Use </think> to close the tag.")
    }

    @Test
    func rejectsOversizedInputBeforeParsing() {
        let input = String(repeating: "x", count: Constants.Speech.maxTextCharacters + 1)
        #expect(throws: SpeechError.tooLong) { try SpeechTextProcessor.prepare(input) }
        let emoji = String(repeating: "🙂", count: Constants.Speech.maxTextCharacters)
        #expect(throws: SpeechError.tooLong) { try SpeechTextProcessor.prepare(emoji) }
    }

    @Test
    func chunksSentencesWithoutDroppingWords() {
        let text = (0..<30).map { "Sentence \($0) is a complete thought with enough words for natural narration." }.joined(separator: " ")
        let chunks = SpeechTextProcessor.split(text)
        #expect(chunks.count > 2)
        #expect(chunks.joined(separator: " ") == text)
        #expect(chunks.allSatisfy { $0.count <= Constants.Speech.maxChunkCharacters && $0.hasSuffix(".") })
        let longSentence = String(repeating: "hello ", count: 250) + "world."
        #expect(SpeechTextProcessor.split(longSentence).joined(separator: " ") == longSentence)
        #expect(SpeechTextProcessor.split("   ").isEmpty)
    }

    @Test(arguments: ["🙂", "👩🏽‍💻", "e\u{301}"])
    func neverSplitsAGrapheme(character: String) {
        let text = String(repeating: character, count: Constants.Speech.maxChunkCharacters * 2 + 1)
        let chunks = SpeechTextProcessor.split(text)
        #expect(chunks.count == 3)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.count <= Constants.Speech.maxChunkCharacters })
    }

    @Test
    func onlyCompletedAssistantResponseTextIsEligible() {
        var message = Message(role: .assistant, content: "Answer.", thoughts: "Private reasoning")
        #expect(SpeechTextProcessor.source(for: message) == "Answer.")
        #expect(SpeechTextProcessor.canRead(message))
        message.isStreaming = true
        #expect(!SpeechTextProcessor.canRead(message))
        message.isStreaming = false
        message.isThinking = true
        #expect(!SpeechTextProcessor.canRead(message))
        message.isThinking = false
        message.streamError = "Failed"
        #expect(!SpeechTextProcessor.canRead(message))
        message.streamError = nil
        message.isError = true
        #expect(!SpeechTextProcessor.canRead(message))
        #expect(!SpeechTextProcessor.canRead(Message(role: .user, content: "Question")))
        #expect(!SpeechTextProcessor.canRead(Message(role: .assistant, content: "<think>Private reasoning")))
    }

    @Test
    func segmentFallbackExcludesToolsSearchesAndThoughts() {
        var message = Message(role: .assistant, content: "")
        message.segments = [.thinking(content: "Private", isThinking: false, duration: nil), .text("First."), .webSearch(searchId: "search"), .toolCall(toolCallId: "tool"), .text("Second.")]
        #expect(SpeechTextProcessor.source(for: message) == "First.\nSecond.")
    }
}
