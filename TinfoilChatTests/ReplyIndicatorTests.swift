import Testing
@testable import TinfoilChat

@MainActor
struct ReplyIndicatorTests {
    private func reply(_ segments: [MessageSegment], searching: Bool = false) -> Message {
        var message = Message(role: .assistant, content: "")
        message.webSearches = [WebSearchInstance(id: "search", query: "tides", status: searching ? .searching : .completed, sources: [], reason: nil)]
        message.toolCalls = [GenUIToolCall(id: "widget", name: "render_chart", arguments: "{}")]
        message.segments = segments
        for case .text(let text) in segments { message.content += text }
        return message
    }

    private func showsIndicator(_ message: Message) -> Bool {
        MessageView.showsIndicatorBelowReply(message, isRenderingStream: true)
    }

    @Test func showsUnderTextThatIsStreaming() {
        let message = reply([.thinking(content: "Plan", isThinking: false, duration: 2), .text("The answer")])
        #expect(showsIndicator(message))
        #expect(!MessageView.showsIndicatorBelowReply(message, isRenderingStream: false))
    }

    @Test func hidesWhileTheLatestStepShowsItIsWorking() {
        #expect(!showsIndicator(reply([.text("Intro"), .thinking(content: "Hmm", isThinking: true, duration: nil)])))
        #expect(!showsIndicator(reply([.webSearch(searchId: "search")], searching: true)))
        // A run of steps that is the latest row reads "Working" once its steps settle.
        #expect(!showsIndicator(reply([.thinking(content: "Plan", isThinking: false, duration: 2), .webSearch(searchId: "search")])))
    }

    @Test func showsUnderAStepThatSettledOnItsOwn() {
        #expect(showsIndicator(reply([.webSearch(searchId: "search")])))
        #expect(showsIndicator(reply([.text("Intro"), .thinking(content: "Plan", isThinking: false, duration: 2)])))
    }

    @Test func showsUnderAWidget() {
        #expect(showsIndicator(reply([.thinking(content: "Plan", isThinking: false, duration: 2), .toolCall(toolCallId: "widget")])))
    }

    @Test func leavesAReplyNothingArrivedOfToItsWaitingDots() {
        #expect(!showsIndicator(Message(role: .assistant, content: "")))
    }

    @Test func followsAReplyWithoutSegments() {
        var thinking = Message(role: .assistant, content: "")
        thinking.isThinking = true
        thinking.thoughts = "Hmm"
        #expect(!showsIndicator(thinking))

        thinking.isThinking = false
        thinking.content = "The answer"
        #expect(showsIndicator(thinking))
    }
}
