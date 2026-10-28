import Foundation
import OpenAPIRuntime

/// Applies a run's frames to a chat's state, as the protocol's recorded runs
/// expect every client to.
enum ChatReducer {
    /// A reply's reasoning streams under the reply's id with this suffix.
    private static let reasoningSuffix = "-reasoning"
    /// A tool's activity streams under the tool call's id with this prefix.
    private static let activityPrefix = "act_"
    /// The status of a widget call's result when the harness refused its
    /// arguments and asked the model to call the widget again.
    private static let refusedWidgetStatus = "error"

    /// The events of a widget's retry that the chat applies: the call redrawn
    /// from its new arguments, and what the call read for them, as a link
    /// preview's page. The run reports the reply it redrew as its own, under
    /// the model the chat has now.
    private static let widgetRetryEvents: Set<HarnessEventType> = [.toolCallStart, .toolCallArgs, .toolCallEnd, .toolCallResult]

    /// Applies one frame of a run. A frame the state applied already, as
    /// when a run is replayed from its first frame, returns the state itself.
    /// A widget's retry redraws the widget and leaves the chat's run, status
    /// and error as they were. A frame that breaks the protocol fails the
    /// stream.
    static func reduce(
        _ state: ChatState,
        _ frame: Frame,
        runHint: String? = nil,
        widgetRetry: Bool = false
    ) throws -> ChatState {
        let event = frame.event
        let runId = event.runId ?? runHint ?? state.runId
        if let id = frame.id, let runId, let applied = state.cursors[runId], id <= applied {
            return state
        }
        var next = state
        if let id = frame.id, let runId { next.cursors[runId] = id }
        if widgetRetry, !widgetRetryEvents.contains(event.type) { return next }
        // A queued run has its own stream. Its cancellation cannot stop the
        // active run, and late frames from the previous run cannot modify a
        // newer snapshot.
        if !widgetRetry, let runId, let current = state.runId, runId != current,
           event.type != .runStarted, event.type != .stateDelta {
            if event.isTerminal { next.snapshot.queue = withoutQueued(next.snapshot.queue, runId) }
            return next
        }
        switch event {
        case .runStarted(let started):
            next.error = nil
            next.failedRun = nil
            next.sealed = [:]
            next.continued = nil
            next.summaries = [:]
            next.runId = started.runId
            next.status = .streaming
            if let messageId = started.messageId {
                next.continued = messageId
                next.sealed = sealOf(next.messages, messageId)
            }
        case .stateSnapshot(let snapshot):
            next.snapshot = RunSnapshot(
                thread: snapshot.snapshot.thread,
                queue: snapshot.snapshot.queue,
                rateLimit: snapshot.snapshot.rateLimit
            )
        case .stateDelta(let delta):
            next.snapshot = try applyStateDelta(next.snapshot, delta.delta)
            if let runId = delta.runId, next.status != .streaming {
                next.status = .queued
                next.runId = runId
            }
        case .messagesSnapshot(let snapshot):
            let shown = afterLoaded(next, snapshot.messages, hasOlder: snapshot.hasOlder)
            next.messages = shown.messages
            next.hasOlder = shown.hasOlder
            // The window holds the continued reply as the harness stored it.
            if let continued = next.continued { next.sealed = sealOf(next.messages, continued) }
        case .textMessageChunk(let chunk):
            next.messages = appendChunk(next, id: chunk.messageId, delta: chunk.delta, timestamp: chunk.timestamp, thinking: false)
        case .reasoningMessageChunk(let chunk):
            let id = chunk.messageId.hasSuffix(reasoningSuffix)
                ? String(chunk.messageId.dropLast(reasoningSuffix.count))
                : chunk.messageId
            next.messages = appendChunk(next, id: id, delta: chunk.delta, timestamp: chunk.timestamp, thinking: true)
        case .reasoningSummary(let summary):
            next.summaries[summary.blockId] = summary.content
        case .toolCallStart(let start):
            let at = millis(of: start.timestamp)
            let restarted = withToolCall(next.messages, start.toolCallId) { block in
                block.invalidArguments = nil
                block.arguments = ""
                block.name = start.toolCallName
                block.complete = false
            }
            next.messages = restarted ?? withReply(
                next.messages,
                id: start.parentMessageId ?? "msg_\(start.toolCallId)",
                createdAt: start.timestamp
            ) { blocks in
                blocks.append(TimelineBlock(
                    id: start.toolCallId,
                    _type: .named(.toolCall),
                    toolCallId: start.toolCallId,
                    name: start.toolCallName,
                    arguments: "",
                    complete: false,
                    progress: [],
                    startedAt: at
                ))
            }
        case .toolCallArgs(let args):
            next.messages = withToolCall(next.messages, args.toolCallId) { block in
                block.arguments = (block.arguments ?? "") + args.delta
            } ?? next.messages
        case .toolCallEnd(let end):
            next.messages = withToolCall(next.messages, end.toolCallId) { block in
                block.complete = true
            } ?? next.messages
        case .toolCallResult(let result):
            let at = millis(of: result.timestamp)
            next.messages = withToolCall(next.messages, result.toolCallId) { block in
                block.result = result.content
                block.metadata = result.metadata.flatMap { try? Components.Schemas.Json(unvalidatedValue: $0.additionalProperties.value) }
                if let display = result.display { block.display = display }
                if refusesWidget(block, result.content) { block.invalidArguments = true }
                if let at, block.startedAt.map({ at >= $0 }) ?? true { block.endedAt = at }
            } ?? next.messages
        case .activitySnapshot(let snapshot):
            let toolCallId = stripped(snapshot.messageId, prefix: activityPrefix)
            next.messages = withToolCall(next.messages, toolCallId) { block in
                project(snapshot.content, onto: &block)
                if let display = snapshot.display { block.display = display }
            } ?? next.messages
        case .activityDelta(let delta):
            let toolCallId = stripped(delta.messageId, prefix: activityPrefix)
            var failure: Error?
            let messages = withToolCall(next.messages, toolCallId) { block in
                do {
                    project(try applyActivityDelta(gathered(block), delta.patch), onto: &block)
                } catch {
                    failure = error
                }
                if let display = delta.display { block.display = display }
            }
            if let failure { throw failure }
            next.messages = messages ?? next.messages
        case .runFinished(let finished):
            next.snapshot.queue = withoutQueued(next.snapshot.queue, runId)
            next.status = .idle
            next.messages = committed(next.messages, finished.metadata.messages)
        case .runError(let failed):
            next.snapshot.queue = withoutQueued(next.snapshot.queue, runId)
            next.status = .error
            next.error = failed.error
            next.failedRun = runId
            if failed.error.code == HarnessErrorCode.chatFlagged { next.flagged = true }
            next.messages = committed(next.messages, failed.metadata?.messages)
        }
        return next
    }

    /// A window of the chat's latest messages, after the earlier messages the
    /// view loaded before the window's first.
    static func afterLoaded(
        _ view: ChatState,
        _ messages: [HarnessMessage],
        hasOlder: Bool
    ) -> (messages: [HarnessMessage], hasOlder: Bool) {
        let messages = messages.shown
        guard let first = messages.first,
              let start = view.messages.firstIndex(where: { $0.id == first.id }),
              start > 0 else {
            return (messages, hasOlder)
        }
        return (Array(view.messages[..<start]) + messages, view.hasOlder)
    }

    private static func invalidPatch() -> HarnessError {
        HarnessError.invalidStream("The chat stream contained an invalid state patch.")
    }

    /// The queue and title changes a run sends.
    private static func applyStateDelta(
        _ snapshot: RunSnapshot,
        _ patches: [Components.Schemas.StatePatch]
    ) throws -> RunSnapshot {
        var next = snapshot
        for patch in patches {
            // The patches share their shape but for the value, so one is told
            // apart by its path, not by the form it happened to read as.
            switch patch {
            case .case1(let add) where add.op.value as? String == "add" && add.path.value as? String == "/queue/-":
                next.queue.append(add.value)
            case .case2(let replace) where replace.op.value as? String == "replace" && replace.path.value as? String == "/queue":
                next.queue = replace.value
            case .case3(let replace) where replace.op.value as? String == "replace":
                switch replace.path.value as? String {
                case "/thread/title":
                    next.thread?.title = replace.value
                case "/thread/titleState":
                    next.thread?.titleState = Components.Schemas.TitleState(raw: replace.value)
                default:
                    throw invalidPatch()
                }
            case .case4(let replace) where replace.op.value as? String == "replace" && replace.path.value as? String == "/thread/titleState":
                next.thread?.titleState = replace.value
            default:
                throw invalidPatch()
            }
        }
        return next
    }

    /// A tool's progress and the output lines it adds.
    private static func applyActivityDelta(
        _ activity: ToolActivity,
        _ patches: [Components.Schemas.ActivityPatch]
    ) throws -> ToolActivity {
        var next = activity
        for patch in patches {
            switch patch {
            case .case1(let replace) where replace.op.value as? String == "replace" && replace.path.value as? String == "/progress":
                next.progress = replace.value
            case .case2(let add) where add.op.value as? String == "add" && add.path.value as? String == "/output/-":
                next.output.append(Components.Schemas.Json(stringLiteral: add.value))
            default:
                throw invalidPatch()
            }
        }
        return next
    }

    /// The output a block gathered from its earlier activity events, if any.
    private static func gathered(_ block: TimelineBlock) -> ToolActivity {
        if let activity = block.activity, let data = try? JSONEncoder().encode(activity),
           let gathered = try? JSONDecoder().decode(ToolActivity.self, from: data) {
            return gathered
        }
        return ToolActivity(toolCallId: block.toolCallId ?? block.id, tool: block.name ?? "", progress: 0, output: [])
    }

    /// Keeps a tool's activity on its block, and the lines it printed as the
    /// block's progress.
    private static func project(_ activity: ToolActivity, onto block: inout TimelineBlock) {
        if let data = try? JSONEncoder().encode(activity),
           let json = try? JSONDecoder().decode(Components.Schemas.Json.self, from: data) {
            block.activity = json
        }
        block.progress = activity.output
    }

    /// Changes the timeline of a reply, which the first chunk naming it
    /// starts.
    private static func withReply(
        _ messages: [HarnessMessage],
        id: String,
        createdAt: String?,
        change: (inout [TimelineBlock]) -> Void
    ) -> [HarnessMessage] {
        var messages = messages
        if let index = messages.firstIndex(where: { $0.id == id }) {
            var timeline = messages[index].timeline ?? []
            change(&timeline)
            messages[index].timeline = timeline
        } else {
            var timeline: [TimelineBlock] = []
            change(&timeline)
            messages.append(HarnessMessage(id: id, role: .named(.assistant), createdAt: createdAt ?? "", timeline: timeline))
        }
        return messages
    }

    /// Changes a tool call's block, wherever it is; nil when no block has it.
    private static func withToolCall(
        _ messages: [HarnessMessage],
        _ toolCallId: String,
        change: (inout TimelineBlock) -> Void
    ) -> [HarnessMessage]? {
        for (index, message) in messages.enumerated() {
            guard var timeline = message.timeline,
                  let at = timeline.firstIndex(where: { $0._type.value1 == .toolCall && ($0.toolCallId ?? $0.id) == toolCallId }) else {
                continue
            }
            change(&timeline[at])
            var messages = messages
            messages[index].timeline = timeline
            return messages
        }
        return nil
    }

    /// Appends a chunk of a reply's text or reasoning to its timeline.
    private static func appendChunk(
        _ state: ChatState,
        id: String,
        delta: String,
        timestamp: String?,
        thinking: Bool
    ) -> [HarnessMessage] {
        let type: TimelineBlock._TypePayload.Value1Payload = thinking ? .thinking : .content
        let sealed = state.sealed[id] ?? 0
        let at = millis(of: timestamp)
        return withReply(state.messages, id: id, createdAt: timestamp) { blocks in
            // Reasoning that arrives after the reply's text began is the tail
            // of the reasoning before that text, as the harness keeps it.
            if thinking, blocks.count - 2 >= sealed, blocks.count >= 2,
               blocks[blocks.count - 1]._type.value1 == .content, blocks[blocks.count - 2]._type.value1 == .thinking {
                blocks[blocks.count - 2].content = (blocks[blocks.count - 2].content ?? "") + delta
                return
            }
            if let last = blocks.last, last._type.value1 == type, blocks.count > sealed {
                blocks[blocks.count - 1].content = (last.content ?? "") + delta
                if thinking { thoughtUntil(&blocks[blocks.count - 1], at) }
                return
            }
            var block = TimelineBlock(id: "\(id)_\(type.rawValue)_\(blocks.count)", _type: .named(type), content: delta)
            if thinking, let at {
                block.startedAt = at
                block.endedAt = at
            }
            blocks.append(block)
        }
    }

    /// How long a reasoning block has thought by a chunk at `at`, as the
    /// harness stores it.
    private static func thoughtUntil(_ block: inout TimelineBlock, _ at: Double?) {
        guard let startedAt = block.startedAt, let at, at >= startedAt else { return }
        block.endedAt = at
        let duration = (at - startedAt) / 1000
        if duration > 0 { block.duration = duration }
    }

    /// The leading blocks of a continued reply that new text does not extend.
    private static func sealOf(_ messages: [HarnessMessage], _ id: String) -> [String: Int] {
        let blocks = messages.first { $0.id == id }?.timeline ?? []
        return [id: blocks.count - (blocks.last?._type.value1 == .content ? 1 : 0)]
    }

    private static func withoutQueued(_ queue: [QueueItem], _ runId: String?) -> [QueueItem] {
        queue.filter { $0.queueId != runId }
    }

    /// What the run committed to each reply beyond its streamed content.
    private static func committed(_ messages: [HarnessMessage], _ replies: [CommittedReply]?) -> [HarnessMessage] {
        guard let replies, !replies.isEmpty else { return messages }
        return messages.map { message in
            guard let reply = replies.first(where: { $0.id == message.id }) else { return message }
            var message = message
            if let model = reply.model { message.model = model }
            if let modelDisplayName = reply.modelDisplayName { message.modelDisplayName = modelDisplayName }
            if let usage = reply.usage { message.usage = usage }
            if let isError = reply.isError { message.isError = isError }
            if let isInterrupted = reply.isInterrupted { message.isInterrupted = isInterrupted }
            if let annotations = reply.annotations { message.annotations = annotations }
            return message
        }
    }

    /// Whether a widget call's result refuses the arguments it was drawn from.
    private static func refusesWidget(_ block: TimelineBlock, _ result: Components.Schemas.Json) -> Bool {
        guard block.name?.hasPrefix(harnessWidgetPrefix) == true,
              let object = result.value as? [String: Any] else { return false }
        return object["status"] as? String == refusedWidgetStatus
    }

    private static func stripped(_ id: String, prefix: String) -> String {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    private static let fractionalTimestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeTimestamps = ISO8601DateFormatter()

    /// When an event happened, in epoch milliseconds, if it says.
    static func millis(of timestamp: String?) -> Double? {
        guard let timestamp,
              let date = fractionalTimestamps.date(from: timestamp) ?? wholeTimestamps.date(from: timestamp) else {
            return nil
        }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }
}
