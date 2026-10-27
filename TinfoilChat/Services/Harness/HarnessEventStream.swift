import Foundation

/// One event of a run's stream, as Protocol/Schemas.swift describes it. A
/// RUN_ERROR is read as an error this client handles by its action, so a
/// code or action a later harness adds does not make the event unreadable.
enum RunEvent: Equatable, Sendable {
    case runStarted(Components.Schemas.RunStartedEvent)
    case messagesSnapshot(Components.Schemas.MessagesSnapshotEvent)
    case stateSnapshot(Components.Schemas.StateSnapshotEvent)
    case stateDelta(Components.Schemas.StateDeltaEvent)
    case textMessageChunk(Components.Schemas.TextMessageChunkEvent)
    case reasoningMessageChunk(Components.Schemas.ReasoningMessageChunkEvent)
    case reasoningSummary(Components.Schemas.ReasoningSummaryEvent)
    case toolCallStart(Components.Schemas.ToolCallStartEvent)
    case toolCallArgs(Components.Schemas.ToolCallArgsEvent)
    case toolCallEnd(Components.Schemas.ToolCallEndEvent)
    case toolCallResult(Components.Schemas.ToolCallResultEvent)
    case activitySnapshot(Components.Schemas.ActivitySnapshotEvent)
    case activityDelta(Components.Schemas.ActivityDeltaEvent)
    case runFinished(RunFinished)
    case runError(RunError)

    var type: HarnessEventType {
        switch self {
        case .runStarted: return .runStarted
        case .messagesSnapshot: return .messagesSnapshot
        case .stateSnapshot: return .stateSnapshot
        case .stateDelta: return .stateDelta
        case .textMessageChunk: return .textMessageChunk
        case .reasoningMessageChunk: return .reasoningMessageChunk
        case .reasoningSummary: return .reasoningSummary
        case .toolCallStart: return .toolCallStart
        case .toolCallArgs: return .toolCallArgs
        case .toolCallEnd: return .toolCallEnd
        case .toolCallResult: return .toolCallResult
        case .activitySnapshot: return .activitySnapshot
        case .activityDelta: return .activityDelta
        case .runFinished: return .runFinished
        case .runError: return .runError
        }
    }

    /// Whether the event ends its run.
    var isTerminal: Bool {
        switch self {
        case .runFinished, .runError: return true
        default: return false
        }
    }

    /// The run the event is about, when it says.
    var runId: String? {
        switch self {
        case .runStarted(let event): return event.runId
        case .stateDelta(let event): return event.runId
        case .runFinished(let event): return event.runId
        case .runError(let event): return event.runId
        default: return nil
        }
    }
}

/// Ends a run, with what it reports. A device run's final event carries the
/// whole chat, kept as the harness sent it, members this client does not
/// know included.
struct RunFinished: Equatable, Sendable {
    let event: Components.Schemas.RunFinishedEvent
    let thread: StoredThread?

    var threadId: String { event.threadId }
    var runId: String { event.runId }
    var metadata: Components.Schemas.RunMetadata { event.metadata }
}

/// Ends a run that failed, with the members of an error. One a stream ends
/// with after its run was lost names neither the chat nor the run.
struct RunError: Equatable, Sendable, Decodable {
    var threadId: String?
    var runId: String?
    var error: HarnessErrorBody
    var metadata: Components.Schemas.RunMetadata?
    /// The whole chat a device run returns, as the harness sent it.
    var thread: StoredThread?

    private enum CodingKeys: String, CodingKey {
        case threadId, runId, metadata
    }

    init(threadId: String? = nil, runId: String? = nil, error: HarnessErrorBody, metadata: Components.Schemas.RunMetadata? = nil) {
        self.threadId = threadId
        self.runId = runId
        self.error = error
        self.metadata = metadata
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        metadata = try container.decodeIfPresent(Components.Schemas.RunMetadata.self, forKey: .metadata)
        error = try HarnessErrorBody(from: decoder)
    }
}

/// One frame of a run's stream: an event and its cursor in the run, which a
/// client following the run again sends back as Last-Event-ID.
struct Frame: Equatable, Sendable {
    let event: RunEvent
    let id: Int?
}

/// Reads a run's server-sent events from the bytes of its response body.
enum HarnessEventStream {
    /// A frame's data, in bytes, beyond which the stream is not one this
    /// client reads.
    static let maximumFrameBytes = 8 * 1024 * 1024

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let colon = UInt8(ascii: ":")
    private static let space = UInt8(ascii: " ")

    private struct EventType: Decodable {
        let type: String
    }

    /// The frames of a stream. Lines are split before the bytes are read as
    /// UTF-8, so a character, a CRLF, a comment or a multi-line event split
    /// across chunks survives. A stream that ends without the run's last
    /// event fails as interrupted: the run may go on.
    static func frames(
        from chunks: AsyncThrowingStream<Data, Error>
    ) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await read(chunks) { frame in continuation.yield(frame) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func read(
        _ chunks: AsyncThrowingStream<Data, Error>,
        emit: (Frame) -> Void
    ) async throws {
        var buffer: [UInt8] = []
        var data: [UInt8] = []
        var hasData = false
        var id: Int?
        var terminal = false
        var done = false
        var iterator = chunks.makeAsyncIterator()
        while !done {
            if let chunk = try await iterator.next() {
                buffer.append(contentsOf: chunk)
            } else {
                done = true
            }
            var start = 0
            while start < buffer.count {
                guard let end = buffer[start...].firstIndex(where: { $0 == lineFeed || $0 == carriageReturn }) else { break }
                // A CR that ends the buffer may be the first half of a CRLF.
                if buffer[end] == carriageReturn, end == buffer.count - 1, !done { break }
                let line = buffer[start..<end]
                start = end + (buffer[end] == carriageReturn && end + 1 < buffer.count && buffer[end + 1] == lineFeed ? 2 : 1)
                if line.isEmpty {
                    if hasData, let frame = try decode(data, id: id) {
                        terminal = terminal || frame.event.isTerminal
                        emit(frame)
                    }
                    data = []
                    hasData = false
                    id = nil
                } else if line.first != colon {
                    let separator = line.firstIndex(of: colon)
                    let field = line[line.startIndex..<(separator ?? line.endIndex)]
                    var value = separator.map { line[($0 + 1)...] } ?? line[line.endIndex...]
                    if value.first == space { value = value.dropFirst() }
                    if field.elementsEqual("data".utf8) {
                        if hasData { data.append(lineFeed) }
                        data.append(contentsOf: value)
                        hasData = true
                    } else if field.elementsEqual("id".utf8) {
                        id = try cursor(value)
                    }
                }
                if data.count > maximumFrameBytes { throw oversized }
            }
            buffer.removeFirst(start)
            if data.count + buffer.count > maximumFrameBytes { throw oversized }
        }
        if !terminal { throw HarnessError.streamInterrupted }
    }

    private static let oversized = HarnessError.invalidStream("The chat event exceeded its size limit.")

    /// A frame's cursor: a non-negative integer.
    private static func cursor(_ value: ArraySlice<UInt8>) throws -> Int {
        guard !value.isEmpty, value.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let id = Int(String(decoding: value, as: UTF8.self)) else {
            throw HarnessError.invalidStream("The chat stream contained an invalid cursor.")
        }
        return id
    }

    /// The frame an event's data holds. One of a type this client does not
    /// know is ignored, as a later harness may send; one of a known type
    /// that does not read as the protocol describes it fails the stream.
    static func decode(_ data: [UInt8], id: Int?) throws -> Frame? {
        let bytes = Data(data)
        let decoder = JSONDecoder()
        guard let named = try? decoder.decode(EventType.self, from: bytes) else {
            throw HarnessError.invalidStream("The chat stream contained an invalid event.")
        }
        guard let type = HarnessEventType(rawValue: named.type) else { return nil }
        do {
            return Frame(event: try event(of: type, from: bytes, decoder), id: id)
        } catch {
            throw HarnessError.invalidStream("The chat stream contained an invalid \(named.type) event.")
        }
    }

    private static func event(of type: HarnessEventType, from bytes: Data, _ decoder: JSONDecoder) throws -> RunEvent {
        switch type {
        case .runStarted: return .runStarted(try decoder.decode(Components.Schemas.RunStartedEvent.self, from: bytes))
        case .messagesSnapshot: return .messagesSnapshot(try decoder.decode(Components.Schemas.MessagesSnapshotEvent.self, from: bytes))
        case .stateSnapshot: return .stateSnapshot(try decoder.decode(Components.Schemas.StateSnapshotEvent.self, from: bytes))
        case .stateDelta: return .stateDelta(try decoder.decode(Components.Schemas.StateDeltaEvent.self, from: bytes))
        case .textMessageChunk: return .textMessageChunk(try decoder.decode(Components.Schemas.TextMessageChunkEvent.self, from: bytes))
        case .reasoningMessageChunk: return .reasoningMessageChunk(try decoder.decode(Components.Schemas.ReasoningMessageChunkEvent.self, from: bytes))
        case .reasoningSummary: return .reasoningSummary(try decoder.decode(Components.Schemas.ReasoningSummaryEvent.self, from: bytes))
        case .toolCallStart: return .toolCallStart(try decoder.decode(Components.Schemas.ToolCallStartEvent.self, from: bytes))
        case .toolCallArgs: return .toolCallArgs(try decoder.decode(Components.Schemas.ToolCallArgsEvent.self, from: bytes))
        case .toolCallEnd: return .toolCallEnd(try decoder.decode(Components.Schemas.ToolCallEndEvent.self, from: bytes))
        case .toolCallResult: return .toolCallResult(try decoder.decode(Components.Schemas.ToolCallResultEvent.self, from: bytes))
        case .activitySnapshot: return .activitySnapshot(try decoder.decode(Components.Schemas.ActivitySnapshotEvent.self, from: bytes))
        case .activityDelta: return .activityDelta(try decoder.decode(Components.Schemas.ActivityDeltaEvent.self, from: bytes))
        case .runFinished:
            return .runFinished(RunFinished(event: try decoder.decode(Components.Schemas.RunFinishedEvent.self, from: bytes), thread: returnedThread(bytes)))
        case .runError:
            var failed = try decoder.decode(RunError.self, from: bytes)
            failed.thread = returnedThread(bytes)
            return .runError(failed)
        }
    }

    /// The chat a terminal event's metadata carries, whole.
    private static func returnedThread(_ bytes: Data) -> StoredThread? {
        guard let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let metadata = event["metadata"] as? [String: Any],
              let thread = metadata["thread"] as? [String: Any] else { return nil }
        return StoredThread(json: thread)
    }
}
