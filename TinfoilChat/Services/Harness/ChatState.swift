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

    /// The state before any run, of a chat as it was loaded, or of a new one.
    init(thread: ThreadWindow? = nil) {
        snapshot = RunSnapshot(thread: thread.map(ThreadSummary.init(of:)))
        messages = thread?.messages ?? []
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
