import Foundation
import Testing
@testable import TinfoilChat

struct SpeechTextTests {
    @Test
    func onlyCompletedAssistantResponseTextIsEligible() {
        var message = Message(role: .assistant, content: "Answer.")
        message.thoughts = "Private reasoning"
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
        #expect(!SpeechTextProcessor.canRead(Message(role: .assistant, content: "   ")))
    }

    @Test
    func segmentFallbackExcludesToolsSearchesAndThoughts() {
        var message = Message(role: .assistant, content: "")
        message.segments = [.thinking(content: "Private", isThinking: false, duration: nil), .text("First."), .webSearch(searchId: "search"), .toolCall(toolCallId: "tool"), .text("Second.")]
        #expect(SpeechTextProcessor.source(for: message) == "First.\nSecond.")
    }
}
