import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct ChatRecoveryDraftStoreTests {
    @Test func replacesWholeSnapshotsAndRejectsStaleGenerations() {
        let store = ChatRecoveryDraftStore()
        store.reset(generation: 3)
        var first = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "First",
            thoughts: "Reasoning"
        )
        first.urlFetches = [
            URLFetchState(id: "fetch-1", url: "https://example.com", status: .fetching)
        ]
        store.replace(
            first,
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 3
        )

        let replacement = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Replacement"
        )
        store.replace(
            replacement,
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 3
        )
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Stale"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 2
        )

        let stored = store.drafts[
            ChatRecoveryDraftKey(chatId: "chat-1", turnId: "turn-1")
        ]
        #expect(stored?.content == "Replacement")
        #expect(stored?.thoughts == nil)
        #expect(stored?.urlFetches.isEmpty == true)
        #expect(stored?.isStreaming == true)
    }

    @Test func rejectsDraftsFromSupersededScans() {
        let store = ChatRecoveryDraftStore()
        store.reset(generation: 1)
        store.beginScan(generation: 4)
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Current"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 1,
            scanGeneration: 4
        )

        store.beginScan(generation: 5)
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Stale"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 1,
            scanGeneration: 4
        )
        #expect(store.drafts.values.first?.content == "Current")

        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Fresh"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 1,
            scanGeneration: 5
        )
        #expect(store.drafts.values.first?.content == "Fresh")
    }

    @Test func prunesByChatAndResetClearsEveryDraft() {
        let store = ChatRecoveryDraftStore()
        let drafts = [
            ("chat-1", "turn-1"),
            ("chat-1", "turn-2"),
            ("chat-2", "turn-1"),
        ]
        for (chatId, turnId) in drafts {
            store.replace(
                Message(role: .assistant, turnId: turnId, content: turnId),
                chatId: chatId,
                turnId: turnId,
                generation: 0
            )
        }

        store.prune(chatId: "chat-1", retaining: ["turn-2"])

        #expect(store.drafts.keys.contains(
            ChatRecoveryDraftKey(chatId: "chat-1", turnId: "turn-2")
        ))
        #expect(!store.drafts.keys.contains(
            ChatRecoveryDraftKey(chatId: "chat-1", turnId: "turn-1")
        ))
        #expect(store.drafts.keys.contains(
            ChatRecoveryDraftKey(chatId: "chat-2", turnId: "turn-1")
        ))

        store.reset(generation: 1)
        #expect(store.drafts.isEmpty)
    }

    @Test func discardedChatRejectsLateDraftsUntilReset() {
        let store = ChatRecoveryDraftStore()
        store.discard(chatId: "chat-1")
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Late"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 0
        )
        #expect(store.drafts.isEmpty)

        store.reset(generation: 1)
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Current"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 1
        )
        #expect(store.drafts.count == 1)
    }

    @Test func discardedTurnRejectsLateDraftsUntilAllowed() {
        let store = ChatRecoveryDraftStore()
        store.discard(chatId: "chat-1", turnId: "turn-1")
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Late"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 0
        )
        #expect(store.drafts.isEmpty)

        store.allow(chatId: "chat-1", turnId: "turn-1")
        store.replace(
            Message(role: .assistant, turnId: "turn-1", content: "Current"),
            chatId: "chat-1",
            turnId: "turn-1",
            generation: 0
        )
        #expect(store.drafts.count == 1)
    }

    @Test func substitutesPersistedAssistantWithoutChangingTimelineIdentity() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let user = Message(
            id: "user-id",
            role: .user,
            turnId: "turn-1",
            content: "Question"
        )
        let partial = Message(
            id: "assistant-id",
            role: .assistant,
            turnId: "turn-1",
            content: "Old partial",
            timestamp: timestamp
        )
        var draft = Message(
            id: "ephemeral-id",
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered answer",
            thoughts: "Recovered reasoning"
        )
        draft.toolCalls = [
            GenUIToolCall(id: "call-1", name: "example", arguments: "{}")
        ]

        let presented = messagesApplyingRecoveryDrafts(
            [user, partial],
            chatId: "chat-1",
            pendingTurnIds: ["turn-1"],
            drafts: [
                ChatRecoveryDraftKey(chatId: "chat-1", turnId: "turn-1"): draft
            ]
        )

        #expect(presented.count == 2)
        #expect(presented[1].id == "assistant-id")
        #expect(presented[1].timestamp == timestamp)
        #expect(presented[1].content == "Recovered answer")
        #expect(presented[1].thoughts == "Recovered reasoning")
        #expect(presented[1].toolCalls == draft.toolCalls)
        #expect(presented[1].isStreaming)
    }

    @Test func insertsStableAssistantImmediatelyAfterMatchingUser() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let user = Message(
            id: "user-id",
            role: .user,
            turnId: "turn-1",
            content: "Question",
            timestamp: timestamp
        )
        let later = Message(
            id: "later-id",
            role: .user,
            turnId: "turn-2",
            content: "Later"
        )
        let draft = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered"
        )
        let drafts = [
            ChatRecoveryDraftKey(chatId: "chat-1", turnId: "turn-1"): draft
        ]

        let first = messagesApplyingRecoveryDrafts(
            [user, later],
            chatId: "chat-1",
            pendingTurnIds: ["turn-1"],
            drafts: drafts
        )
        let second = messagesApplyingRecoveryDrafts(
            [user, later],
            chatId: "chat-1",
            pendingTurnIds: ["turn-1"],
            drafts: drafts
        )

        #expect(first.map(\.id) == [
            "user-id",
            recoveryDraftMessageId(chatId: "chat-1", turnId: "turn-1"),
            "later-id",
        ])
        #expect(first[1].id == second[1].id)
        #expect(first[1].timestamp == timestamp)
        #expect(first[1].role == .assistant)
        #expect(first[1].isStreaming)
    }

    @Test func ignoresDraftsOutsideThePendingChatTurn() {
        let user = Message(
            role: .user,
            turnId: "turn-1",
            content: "Question"
        )
        let draft = Message(
            role: .assistant,
            turnId: "turn-1",
            content: "Recovered"
        )

        let presented = messagesApplyingRecoveryDrafts(
            [user],
            chatId: "chat-1",
            pendingTurnIds: ["turn-2"],
            drafts: [
                ChatRecoveryDraftKey(chatId: "chat-2", turnId: "turn-1"): draft
            ]
        )

        #expect(presented == [user])
    }
}
