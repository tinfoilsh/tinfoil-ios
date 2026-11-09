import Foundation

/// A run's state as a chat shows it: no chat or quota before the run's first
/// snapshot.
struct RunSnapshot: Equatable, Sendable {
    var thread: ThreadSummary?
    var queue: [QueueItem] = []
    var rateLimit: HarnessRateLimit?
}

/// What a chat shows of its run, as the run's frames build it.
struct ChatState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case idle, submitting, queued, streaming, error
    }

    var snapshot: RunSnapshot
    var messages: [HarnessMessage]
    /// The chat's compaction markers, which its messages leave out, by the
    /// id of the message each one shows above. One whose summary is still
    /// being written has no compaction member yet.
    var markers: [String: HarnessMessage] = [:]
    var hasOlder: Bool
    var runId: String?
    var status: Status
    var error: HarnessErrorBody?
    /// The run that ended with RUN_ERROR. It is run again rather than
    /// rejoined.
    var failedRun: String?
    /// A run continuing a reply streams into it, as RUN_STARTED names it.
    var continued: String?
    /// The leading blocks of a continued reply that new text starts after: as
    /// in the harness, only a trailing text block takes the continuation.
    var sealed: [String: Int] = [:]
    /// The last frame applied of each run, so a replayed run skips the frames
    /// it applied already.
    var cursors: [String: Int] = [:]
    /// The latest summary of each thinking block of the run, by block id.
    var summaries: [String: String] = [:]
    /// The safeguards flagged the chat, as it was loaded or as the harness
    /// refused a turn, so it takes no more turns.
    var flagged = false
    /// The user stopped the run the chat shows, which has not ended yet.
    var stopping = false
    /// The chat's latest turn compacts it on request instead of asking for a
    /// reply, so its last reply is not the one the run streams.
    var compactTurn = false
    /// The compaction marker a run of the chat completed as the chat showed
    /// it, which the chat points out until the user sends again or dismisses
    /// it: the marker sits above earlier messages, often out of view.
    var compacted: String?

    var isRunning: Bool { [.submitting, .streaming, .queued].contains(status) }
    var isStopping: Bool { isRunning && stopping }

    /// The id of the reply a research streams, which is a research before
    /// its run commits it as one: while a turn of the chat runs, the chat's
    /// last message is a reply to a question that asks for deep research. A
    /// compaction streams no reply.
    var researchingReply: String? {
        guard isRunning, !compactTurn, let reply = messages.last, reply.role.value1 == .assistant,
              let question = messages.dropLast().last, question.role.value1 == .user, question.research != nil else { return nil }
        return reply.id
    }

    /// Whether compacting the chat on request has anything to summarize, as
    /// the harness decides it: a message after the latest compaction marker
    /// that comes before the last question, which the harness keeps with its
    /// reply.
    var compactable: Bool {
        guard let question = messages.lastIndex(where: { $0.role.value1 == .user }) else { return false }
        return question > (messages.lastIndex(where: { markers[$0.id] != nil }) ?? 0)
    }

    /// The messages with each compaction marker before the message it shows
    /// above, as the harness keeps them.
    var messagesWithMarkers: [HarnessMessage] {
        messages.flatMap { message -> [HarnessMessage] in
            markers[message.id].map { [$0, message] } ?? [message]
        }
    }

    /// The messages before the chat's latest compaction marker whose summary
    /// was written, which the model reads that summary in place of.
    var summarizedIds: Set<String> {
        guard let latest = messages.lastIndex(where: { markers[$0.id]?.compaction != nil }) else { return [] }
        return Set(messages[..<latest].map(\.id))
    }

    /// The state before any run, of a chat as it was loaded, or of a new one.
    init(thread: ThreadWindow? = nil) {
        snapshot = RunSnapshot(thread: thread.map(ThreadSummary.init(of:)))
        messages = thread?.messages.shown ?? []
        markers = thread?.messages.markers() ?? [:]
        hasOlder = thread?.hasOlder ?? false
        status = .idle
        flagged = thread?.flagged ?? false
    }
}

extension ThreadSummary {
    /// A chat as a list shows it, from the chat as it was opened.
    init(of window: ThreadWindow) {
        self.init(
            id: window.id,
            title: window.title,
            titleState: window.titleState,
            createdAt: window.createdAt,
            updatedAt: window.updatedAt,
            activityAt: window.activityAt,
            projectId: window.projectId,
            model: window.model,
            webSearchEnabled: window.webSearchEnabled,
            pinned: window.pinned,
            contextUsage: window.contextUsage.map {
                ContextUsagePayload(usedTokens: $0.usedTokens, limitTokens: $0.limitTokens, percentage: $0.percentage)
            },
            activeRun: window.activeRun.map {
                ActiveRunPayload(runId: $0.runId, expiresAt: $0.expiresAt, instance: $0.instance)
            },
            messageCount: window.messageCount,
            flagged: window.flagged
        )
    }
}
