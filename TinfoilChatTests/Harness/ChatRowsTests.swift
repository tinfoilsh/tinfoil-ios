import Foundation
import Testing
@testable import TinfoilChat

/// The chat table lays out a turn as main did: the message sent and an empty
/// reply row under it at once, each row keeping its id while the harness
/// replaces the messages it shows.
@Suite("Chat rows")
@MainActor
struct ChatRowsTests {
    private static func user(_ id: String, _ content: String) throws -> HarnessMessage {
        try HarnessMessage(jsonObject: ["id": id, "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": content])
    }

    private static func reply(_ id: String, _ text: String) throws -> HarnessMessage {
        try HarnessMessage(jsonObject: [
            "id": id, "role": "assistant", "createdAt": "2026-01-01T00:00:01Z",
            "timeline": [["id": "\(id)-c", "type": "content", "content": text]],
        ])
    }

    @Test func aTurnShowsItsMessageAndAnEmptyReplyThatTheReplyFillsUnderTheSameIds() throws {
        let rows = ChatRows()
        let earlier = [try Self.user("u0", "Hi"), try Self.reply("r0", "Hello")]
        // The message as sent, under the id the turn named it with.
        let sent = earlier + [try Self.user("client-1", "How are you?")]
        let waiting = rows.rows(chatId: "c", messages: sent, running: true, summaries: [:], replyModelName: "Model")
        #expect(waiting.map(\.role) == [.user, .assistant, .user, .assistant])
        let placeholder = try #require(waiting.last)
        #expect(placeholder.content.isEmpty && placeholder.segments == nil && placeholder.isStreaming)
        #expect(placeholder.modelDisplayName == "Model")

        // The harness stores the message under its own id, then the reply
        // starts under one it chose.
        let stored = earlier + [try Self.user("u1", "How are you?")]
        let replaced = rows.rows(chatId: "c", messages: stored, running: true, summaries: [:], replyModelName: "Model")
        #expect(replaced.map(\.id) == waiting.map(\.id))
        let streaming = rows.rows(chatId: "c", messages: stored + [try Self.reply("r1", "Fine")], running: true, summaries: [:], replyModelName: "Model")
        #expect(streaming.map(\.id) == waiting.map(\.id))
        #expect(streaming.last?.content == "Fine")

        // The rows keep those ids after the reply ends.
        let done = rows.rows(chatId: "c", messages: stored + [try Self.reply("r1", "Fine, thanks")], running: false, summaries: [:], replyModelName: "Model")
        #expect(done.map(\.id) == waiting.map(\.id))
    }

    @Test func aRegeneratedReplyWaitsInARowUnderItsMessage() throws {
        let rows = ChatRows()
        let message = try Self.user("u1", "Again")
        _ = rows.rows(chatId: "c", messages: [message, try Self.reply("r1", "Old")], running: false, summaries: [:], replyModelName: nil)
        let waiting = rows.rows(chatId: "c", messages: [message], running: true, summaries: [:], replyModelName: nil)
        #expect(waiting.map(\.id).first == "u1")
        #expect(waiting.count == 2 && waiting.last?.role == .assistant)
        let regenerated = rows.rows(chatId: "c", messages: [message, try Self.reply("r2", "New")], running: true, summaries: [:], replyModelName: nil)
        #expect(regenerated.map(\.id) == waiting.map(\.id))
    }

    @Test func aTurnThatEndsWithoutAReplyKeepsItsRowForTheError() throws {
        let rows = ChatRows()
        let sent = [try Self.user("client-1", "Hello")]
        let waiting = rows.rows(chatId: "c", messages: sent, running: true, summaries: [:], replyModelName: nil)
        let ended = rows.rows(chatId: "c", messages: sent, running: false, summaries: [:], replyModelName: nil)
        #expect(ended.count == 1)
        #expect(rows.awaitedReplyRowId(sent) == waiting.last?.id)
        // A retry fills the same row.
        let retried = rows.rows(chatId: "c", messages: sent, running: true, summaries: [:], replyModelName: nil)
        #expect(retried.last?.id == waiting.last?.id)
    }

    @Test func aContinuedReplyStreamsIntoItsOwnRow() throws {
        let rows = ChatRows()
        let messages = [try Self.user("u1", "Go on"), try Self.reply("r1", "Part one")]
        let continued = rows.rows(chatId: "c", messages: messages, running: true, summaries: [:], replyModelName: nil)
        #expect(continued.map(\.id) == ["u1", "r1"])
    }

    @Test func anotherChatDoesNotTakeOverTheTurnOfTheChatBefore() throws {
        let rows = ChatRows()
        let waiting = rows.rows(chatId: "a", messages: [try Self.user("client-1", "One")], running: true, summaries: [:], replyModelName: nil)
        // Chat b's last message reads the same as the one chat a sent.
        let other = rows.rows(chatId: "b", messages: [try Self.user("u9", "One")], running: true, summaries: [:], replyModelName: nil)
        #expect(other.first?.id == "u9")
        #expect(other.count == 2 && other.last?.id != waiting.last?.id)
    }

    @Test func aMessageKeptFromTheLastFrameStillTakesItsNewSummaryAndEnd() throws {
        let rows = ChatRows()
        let reply = try HarnessMessage(jsonObject: [
            "id": "r1", "role": "assistant", "createdAt": "2026-01-01T00:00:01Z",
            "timeline": [["id": "t1", "type": "thinking", "content": "Hmm"]],
        ])
        _ = rows.rows(chatId: "c", messages: [reply], running: true, summaries: [:], replyModelName: nil)
        let summarized = rows.rows(chatId: "c", messages: [reply], running: true, summaries: ["t1": "Pondering"], replyModelName: nil)
        #expect(summarized.last?.timeline?.first?.objectValue?["summary"]?.stringValue == "Pondering")
        #expect(summarized.last?.isThinking == true)
        let ended = rows.rows(chatId: "c", messages: [reply], running: false, summaries: ["t1": "Pondering"], replyModelName: nil)
        #expect(ended.last?.isThinking == false)
    }
}
