import Foundation
import Testing
@testable import TinfoilChat

@Suite("Message edit sessions")
struct MessageEditSessionTests {
    private let userMessage = Message(id: "user-message", role: .user, content: "Original")
    private let assistantMessage = Message(id: "assistant-message", role: .assistant, content: "Reply")

    @Test func beginsForAvailableUserMessage() {
        let sessionId = UUID()

        let session = MessageEditSessionTransition.begin(
            id: sessionId,
            chatId: "chat-a",
            messages: [userMessage, assistantMessage],
            messageIndex: 0,
            canUseActions: true,
            isLoading: false
        )

        #expect(session == MessageEditSession(
            id: sessionId,
            chatId: "chat-a",
            messageId: userMessage.id,
            originalContent: "Original"
        ))
    }

    @Test func rejectsUnavailableEditStarts() {
        #expect(MessageEditSessionTransition.begin(
            chatId: "chat-a",
            messages: [assistantMessage],
            messageIndex: 0,
            canUseActions: true,
            isLoading: false
        ) == nil)
        #expect(MessageEditSessionTransition.begin(
            chatId: "chat-a",
            messages: [userMessage],
            messageIndex: 0,
            canUseActions: true,
            isLoading: true
        ) == nil)
        #expect(MessageEditSessionTransition.begin(
            chatId: "chat-a",
            messages: [userMessage],
            messageIndex: 0,
            canUseActions: false,
            isLoading: false
        ) == nil)
    }

    @Test func resolvesSaveByMessageIdAfterMessagesMove() throws {
        let session = try #require(MessageEditSessionTransition.begin(
            chatId: "chat-a",
            messages: [userMessage, assistantMessage],
            messageIndex: 0,
            canUseActions: true,
            isLoading: false
        ))
        let earlierMessage = Message(id: "earlier", role: .assistant, content: "Earlier")

        let index = MessageEditSessionTransition.saveIndex(
            for: session,
            chatId: "chat-a",
            messages: [earlierMessage, userMessage, assistantMessage],
            newContent: "Updated",
            canUseActions: true,
            isLoading: false
        )

        #expect(index == 1)
    }

    @Test func rejectsInvalidSaveTransitions() throws {
        let session = try #require(MessageEditSessionTransition.begin(
            chatId: "chat-a",
            messages: [userMessage],
            messageIndex: 0,
            canUseActions: true,
            isLoading: false
        ))

        #expect(MessageEditSessionTransition.saveIndex(
            for: session,
            chatId: "chat-b",
            messages: [userMessage],
            newContent: "Updated",
            canUseActions: true,
            isLoading: false
        ) == nil)
        #expect(MessageEditSessionTransition.saveIndex(
            for: session,
            chatId: "chat-a",
            messages: [userMessage],
            newContent: " \n\t ",
            canUseActions: true,
            isLoading: false
        ) == nil)
        #expect(MessageEditSessionTransition.saveIndex(
            for: session,
            chatId: "chat-a",
            messages: [],
            newContent: "Updated",
            canUseActions: true,
            isLoading: false
        ) == nil)
        #expect(MessageEditSessionTransition.saveIndex(
            for: session,
            chatId: "chat-a",
            messages: [userMessage],
            newContent: "Updated",
            canUseActions: false,
            isLoading: false
        ) == nil)
        #expect(MessageEditSessionTransition.saveIndex(
            for: session,
            chatId: "chat-a",
            messages: [userMessage],
            newContent: "Updated",
            canUseActions: true,
            isLoading: true
        ) == nil)
    }

    @Test func clearsWhenChatChangesOrMessageDisappears() throws {
        let session = try #require(MessageEditSessionTransition.begin(
            chatId: "chat-a",
            messages: [userMessage],
            messageIndex: 0,
            canUseActions: true,
            isLoading: false
        ))

        #expect(MessageEditSessionTransition.reconcile(
            session,
            chatId: "chat-a",
            messages: [userMessage]
        ) == session)
        #expect(MessageEditSessionTransition.reconcile(
            session,
            chatId: "chat-b",
            messages: [userMessage]
        ) == nil)
        #expect(MessageEditSessionTransition.reconcile(
            session,
            chatId: "chat-a",
            messages: []
        ) == nil)
    }
}
