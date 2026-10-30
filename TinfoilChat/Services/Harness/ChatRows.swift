import Foundation

/// The rows the chat table shows for the open chat. The table measures,
/// animates and scrolls its rows by id, and expects a turn to show its message
/// and the reply under it at once, the reply empty until it streams: the empty
/// row shows the waiting dots and holds the space the message is scrolled up
/// into. The harness answers a turn by storing the message under an id of its
/// own and names the reply only when it starts, so rows keep the ids they were
/// first shown with, and a reply that has not started shows as an empty row
/// the reply then fills.
@MainActor
final class ChatRows {
    /// A turn's message, as first shown, and the row its reply fills.
    private struct Awaited {
        let shownId: String
        let content: String
        let replyRowId: String
        let replyShownAt: Date
    }

    private struct Mapped {
        let wire: HarnessMessage
        let streaming: Bool
        let summaries: [String: String]
        let view: Message
    }

    private var chatId: String?
    /// The ids rows were shown with, by the harness's ids of their messages.
    private var shownIds: [String: String] = [:]
    private var awaited: Awaited?
    /// Messages as last shown, so a frame rebuilds only the messages it changed.
    private var mapped: [String: Mapped] = [:]

    /// The open chat's messages as rows. running says a turn of the chat is
    /// under way; replyModelName names the model on the row a reply waits in.
    func rows(chatId: String?, messages: [HarnessMessage], running: Bool, summaries: [String: String], replyModelName: String?) -> [Message] {
        if chatId != self.chatId {
            // A chat that keeps its messages under another id is the same
            // conversation on screen; another chat starts its rows afresh.
            let sameConversation = self.chatId == nil || messages.contains { mapped[$0.id] != nil || shownIds[$0.id] != nil }
            self.chatId = chatId
            if !sameConversation {
                shownIds = [:]
                awaited = nil
                mapped = [:]
            }
        }
        bindReplacedIds(messages)
        if running, let last = messages.last, last.role.value1 == .user {
            let shownId = shownIds[last.id] ?? last.id
            if awaited?.shownId != shownId {
                awaited = Awaited(shownId: shownId, content: last.content ?? "", replyRowId: UUID().uuidString.lowercased(), replyShownAt: Date())
            }
        }
        var kept: [String: Mapped] = [:]
        var rows = messages.enumerated().map { index, wire -> Message in
            let streaming = running && index == messages.count - 1
            let shownId = shownIds[wire.id] ?? wire.id
            let relevant = Self.summaries(of: wire, in: summaries)
            if let previous = mapped[wire.id], previous.streaming == streaming, previous.view.id == shownId,
               previous.summaries == relevant, previous.wire == wire {
                kept[wire.id] = previous
                return previous.view
            }
            let view = ChatViewMapping.message(wire, streaming: streaming, summaries: relevant, shownAs: shownId)
            kept[wire.id] = Mapped(wire: wire, streaming: streaming, summaries: relevant, view: view)
            return view
        }
        mapped = kept
        if running, let awaited, awaitsReply(messages) {
            var reply = Message(id: awaited.replyRowId, role: .assistant, content: "", timestamp: awaited.replyShownAt)
            reply.isStreaming = true
            reply.modelDisplayName = replyModelName
            rows.append(reply)
        }
        return rows
    }

    /// The harness's id of the message a row shows, which requests about the
    /// message name.
    func messageId(ofRow rowId: String) -> String {
        shownIds.first { $0.value == rowId }?.key ?? rowId
    }

    /// The row of a reply that has not started: the row it waits in, which
    /// shows the error when the turn ends without one.
    func awaitedReplyRowId(_ messages: [HarnessMessage]) -> String? {
        awaitsReply(messages) ? awaited?.replyRowId : nil
    }

    /// Gives the messages a turn replaced the ids their rows were shown with:
    /// the message sent, once the harness stores it under its own id, and the
    /// reply, which fills the row it was awaited in.
    private func bindReplacedIds(_ messages: [HarnessMessage]) {
        guard let awaited, let userIndex = messages.lastIndex(where: { $0.role.value1 == .user }) else { return }
        let user = messages[userIndex]
        if user.id != awaited.shownId, shownIds[user.id] == nil, (user.content ?? "") == awaited.content,
           !messages.contains(where: { (shownIds[$0.id] ?? $0.id) == awaited.shownId }) {
            shownIds[user.id] = awaited.shownId
        }
        guard (shownIds[user.id] ?? user.id) == awaited.shownId, messages.indices.contains(userIndex + 1) else { return }
        let reply = messages[userIndex + 1]
        guard reply.role.value1 == .assistant else { return }
        if shownIds[reply.id] == nil { shownIds[reply.id] = awaited.replyRowId }
        self.awaited = nil
    }

    private func awaitsReply(_ messages: [HarnessMessage]) -> Bool {
        guard let awaited, let last = messages.last, last.role.value1 == .user else { return false }
        return (shownIds[last.id] ?? last.id) == awaited.shownId
    }

    /// The reasoning summaries of a message's own blocks, so a summary of the
    /// reply streaming does not rebuild every other message.
    private static func summaries(of message: HarnessMessage, in summaries: [String: String]) -> [String: String] {
        guard !summaries.isEmpty, let blocks = message.timeline else { return [:] }
        var relevant: [String: String] = [:]
        for block in blocks {
            if let summary = summaries[block.id] { relevant[block.id] = summary }
        }
        return relevant
    }
}
