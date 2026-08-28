import Testing
@testable import TinfoilChat

struct ChatStreamStateTests {
    @Test func tracksStreamsIndependentlyByChat() {
        var state = ChatStreamState()

        state.start(chatId: "chat-a")
        state.start(chatId: "chat-b")

        #expect(state.isStreaming(chatId: "chat-a"))
        #expect(state.isStreaming(chatId: "chat-b"))

        state.finish(chatId: "chat-a")

        #expect(!state.isStreaming(chatId: "chat-a"))
        #expect(state.isStreaming(chatId: "chat-b"))
    }

    @Test func keepsProgressSummariesScopedToTheirChat() {
        var state = ChatStreamState()
        state.start(chatId: "chat-a")
        state.start(chatId: "chat-b")
        state.setThinkingSummary("Planning A", chatId: "chat-a")
        state.setWebSearchSummary("Searching B", chatId: "chat-b")

        state.finish(chatId: "chat-a")

        #expect(state.thinkingSummaries["chat-a"] == nil)
        #expect(state.webSearchSummaries["chat-b"] == "Searching B")
        #expect(state.isStreaming(chatId: "chat-b"))
    }

    @Test func generationCandidatesIncludeTasksActiveStreamsAndRecoveries() {
        var state = ChatStreamState()
        state.start(chatId: "recovered-chat")
        state.start(chatId: "shared-chat")

        let candidates = state.generationCandidateChatIds(
            taskChatIds: ["normal-chat", "shared-chat"],
            recoveryChatIds: ["coordinator-recovery-chat", "shared-chat"]
        )

        #expect(candidates == [
            "coordinator-recovery-chat",
            "recovered-chat",
            "normal-chat",
            "shared-chat",
        ])
    }
}
