import Testing
@testable import TinfoilChat

@Suite("Message input content")
struct MessageInputContentTests {
    @Test("detects visible draft content", arguments: ["hello", "  hello  ", "\nmessage"])
    func visibleContent(text: String) {
        #expect(hasNonWhitespaceContent(text))
    }

    @Test("rejects whitespace-only drafts", arguments: ["", " ", "\n\t"])
    func whitespaceOnlyContent(text: String) {
        #expect(!hasNonWhitespaceContent(text))
    }
}
