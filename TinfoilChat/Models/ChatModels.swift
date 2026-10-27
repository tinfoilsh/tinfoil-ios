//
//  ChatModels.swift
//  TinfoilChat
//
//  What the views show of a chat and its messages, built from what the
//  chat service sends. Nothing here is stored: a chat kept on this device is
//  a StoredThread, and a stored chat lives in the cloud.
//

import Foundation
import UIKit

/// A chat as the views show it.
struct Chat: Identifiable, Equatable {
    enum TitleState: String {
        case placeholder
        case generated
        case manual
    }

    static let placeholderTitle = Constants.Harness.placeholderTitle
    /// What a chat waiting for its generated title shows.
    static let defaultTitle = "Untitled"

    let id: String
    var title: String
    var titleState: TitleState = .placeholder
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date?
    /// When the chat's latest message was written, by which lists order it.
    var activityAt: Date?
    var model: String = ""
    var messageCount: Int = 0
    var isLocalOnly: Bool = false
    var projectId: String?
    var promptPresetId: String?
    var webSearchEnabled: Bool = true
    var pinned: Bool = false
    /// The safeguards flagged the chat, which takes no more turns.
    var flagged: Bool = false
    /// A hint that a reply may be streaming, until the run's deadline.
    var activeRun: ActiveRun?
    /// How much of the model's context the chat uses, as the chat service
    /// reports it.
    var contextUsage: ContextUsage?
    /// Transient flag for ephemeral "temporary" chats, which are never
    /// stored. Powers the toolbar incognito toggle.
    var isTemporary: Bool = false
    /// Transient flag for a chat whose first save is still landing (e.g. a
    /// fork placeholder). Drives the sidebar row spinner.
    var pendingSave: Bool = false

    init(id: String, title: String, messages: [Message] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }

    var isBlankChat: Bool {
        messages.isEmpty && messageCount == 0
    }

    var needsGeneratedTitle: Bool {
        titleState == .placeholder
    }

    /// Last conversation activity: the later of the creation time and the
    /// newest message.
    var lastActivity: Date {
        activityAt ?? messages.reduce(createdAt) { max($0, $1.timestamp) }
    }

    /// Generates a permanent reverse-timestamp ID locally (matching the web app format).
    /// Format: {reverseTimestamp padded to 13 digits}_{UUID}
    static func generateReverseId(timestampMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> String {
        let reverseTimestamp = Constants.Harness.maxReverseTimestamp - timestampMs
        let unpadded = String(reverseTimestamp)
        let reverseTsStr = String(repeating: "0", count: max(0, Constants.Harness.reverseTimestampDigits - unpadded.count)) + unpadded
        return "\(reverseTsStr)_\(UUID().uuidString.lowercased())"
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
}

// MARK: - Web Search Types

/// Represents a source from web search results
struct WebSearchSource: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let url: String
    let snippet: String?

    init(id: String = UUID().uuidString.lowercased(), title: String, url: String, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Generate UUID if id is missing (React app doesn't include it)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
    }

    var timelineValue: JSONValue {
        var fields: [String: JSONValue] = ["title": .string(title), "url": .string(url)]
        if let snippet { fields["snippet"] = .string(snippet) }
        return .object(fields)
    }

    static func fromTimeline(_ value: JSONValue) -> WebSearchSource? {
        guard let fields = value.objectValue,
              let url = fields["url"]?.stringValue else { return nil }
        return WebSearchSource(title: fields["title"]?.stringValue ?? url, url: url, snippet: fields["snippet"]?.stringValue)
    }
}

/// Status of a web search operation
enum WebSearchStatus: String, Codable, Equatable {
    case searching
    case completed
    case failed
    case blocked
}

/// State of web search for a message
struct WebSearchState: Codable, Equatable {
    var query: String?
    var status: WebSearchStatus
    var sources: [WebSearchSource]
    var reason: String?

    init(
        query: String? = nil,
        status: WebSearchStatus = .searching,
        sources: [WebSearchSource] = [],
        reason: String? = nil
    ) {
        self.query = query
        self.status = status
        self.sources = sources
        self.reason = reason
    }
}

// MARK: - URL Fetch Types

/// Status of a URL fetch operation
enum URLFetchStatus: String, Codable, Equatable {
    case fetching
    case completed
    case failed
    case blocked
}

/// Tracks the state of a single URL being fetched during web search
struct URLFetchState: Codable, Equatable, Identifiable {
    let id: String
    let url: String
    var status: URLFetchStatus
    var sources: [WebSearchSource]?
    /// Wall-clock stamps (epoch ms) recorded while streaming; see `WorkRun`.
    var startedAt: Double?
    var endedAt: Double?

    init(
        id: String = UUID().uuidString.lowercased(),
        url: String,
        status: URLFetchStatus = .fetching,
        sources: [WebSearchSource]? = nil,
        startedAt: Double? = nil,
        endedAt: Double? = nil
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.sources = sources
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// A single web search instance referenced by an inline message segment.
struct WebSearchInstance: Codable, Equatable, Identifiable {
    let id: String
    var query: String?
    var status: WebSearchStatus
    var sources: [WebSearchSource]?
    var reason: String?
    /// Wall-clock stamps (epoch ms) recorded while streaming; see `WorkRun`.
    var startedAt: Double? = nil
    var endedAt: Double? = nil
}

/// An ordered segment of assistant content. Preserves the exact order in which
/// text and inline events (thinking, web search, URL fetch, tool call) streamed.
enum MessageSegment: Codable, Equatable {
    case text(String)
    /// `startedAt`/`endedAt` are wall-clock epoch ms stamped while
    /// streaming so a run of trace segments can be summarized as
    /// "Worked for Ns"; absent on legacy messages.
    case thinking(content: String, isThinking: Bool, duration: Double?, startedAt: Double? = nil, endedAt: Double? = nil)
    case webSearch(searchId: String)
    case urlFetch(fetchId: String)
    case toolCall(toolCallId: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case content
        case isThinking
        case duration
        case startedAt
        case endedAt
        case searchId
        case fetchId
        case toolCallId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "thinking":
            let content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            let isThinking = try container.decodeIfPresent(Bool.self, forKey: .isThinking) ?? false
            let duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            let startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
            let endedAt = try container.decodeIfPresent(Double.self, forKey: .endedAt)
            self = .thinking(content: content, isThinking: isThinking, duration: duration, startedAt: startedAt, endedAt: endedAt)
        case "web_search":
            let searchId = try container.decode(String.self, forKey: .searchId)
            self = .webSearch(searchId: searchId)
        case "url_fetch":
            let fetchId = try container.decode(String.self, forKey: .fetchId)
            self = .urlFetch(fetchId: fetchId)
        case "tool_call":
            let toolCallId = try container.decode(String.self, forKey: .toolCallId)
            self = .toolCall(toolCallId: toolCallId)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown segment type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let content, let isThinking, let duration, let startedAt, let endedAt):
            try container.encode("thinking", forKey: .type)
            try container.encode(content, forKey: .content)
            try container.encode(isThinking, forKey: .isThinking)
            try container.encodeIfPresent(duration, forKey: .duration)
            try container.encodeIfPresent(startedAt, forKey: .startedAt)
            try container.encodeIfPresent(endedAt, forKey: .endedAt)
        case .webSearch(let searchId):
            try container.encode("web_search", forKey: .type)
            try container.encode(searchId, forKey: .searchId)
        case .urlFetch(let fetchId):
            try container.encode("url_fetch", forKey: .type)
            try container.encode(fetchId, forKey: .fetchId)
        case .toolCall(let toolCallId):
            try container.encode("tool_call", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
        }
    }

    /// Decodes an array of segments while tolerating individual entries whose
    /// shape is unknown to this client (e.g. a newer platform introduced a
    /// segment type we don't understand). Unrecognized entries are skipped
    /// instead of failing the whole decode.
    static func decodeArrayLenient<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> [MessageSegment]? {
        guard container.contains(key) else { return nil }
        // Decode into a forgiving wrapper that accepts any JSON shape so the
        // unkeyed container reliably advances past unknown entries, then
        // attempt to re-decode each wrapper as a `MessageSegment` via its
        // preserved raw value. Entries that still don't match are dropped.
        let wrappers = try container.decode([LenientSegment].self, forKey: key)
        return wrappers.compactMap { $0.segment }
    }
}

/// Wrapper that decodes any JSON value into an intermediate form and then
/// tries to re-interpret it as a `MessageSegment`. Unknown shapes decode
/// successfully (advancing the unkeyed container) but yield a `nil`
/// segment so callers can drop them.
private struct LenientSegment: Decodable {
    let segment: MessageSegment?

    init(from decoder: Decoder) throws {
        self.segment = try? MessageSegment(from: decoder)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}


enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: JSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
                try container.encode(value, forKey: codingKey)
            }
        }
    }
}

/// URL citation from web search results, matching React's Annotation type
struct URLCitation: Codable, Equatable {
    let title: String
    let url: String
    let start_index: Int?
    let end_index: Int?
}

/// Annotation wrapper, matching React's { type: 'url_citation', url_citation: URLCitation }
struct Annotation: Codable, Equatable {
    let type: String
    let url_citation: URLCitation
}

struct GenUIToolCall: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let arguments: String
}

// `GenUIResolution` (defined in `Views/GenUI/GenUIWidget.swift`) is used
// both as the in-memory render input and the on-disk storage shape. Its
// JSON representation matches the webapp's
// `TimelineToolCallBlock.resolution` so chats round-trip across
// platforms.

/// A user message submitted while the assistant was busy, held until the
/// current response finishes. Mirrors the webapp's `QueuedMessage`.
struct QueuedMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let attachments: [Attachment]

    init(
        id: String = UUID().uuidString.lowercased(),
        text: String,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}

/// Represents a single message in a chat

/// A message as the views show it: a question's text, or a reply's text,
/// reasoning, searches, page reads and widgets, as the chat service's
/// blocks describe them.
struct Message: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    var modelDisplayName: String? = nil
    var thoughts: String? = nil
    var isThinking: Bool = false
    var timestamp: Date
    var isCollapsed: Bool = true
    var isStreaming: Bool = false
    var streamError: String? = nil
    var isRequestError: Bool = false
    var isRateLimitError: Bool = false
    /// True when the rate-limit error is the subscriber hourly usage cap rather
    /// than the free-tier daily limit, so the UI shows a transient
    /// "try again shortly" message instead of an upgrade prompt.
    var isHourlyLimitError: Bool = false
    /// True when the stream failed on connectivity, so the error card shows
    /// the wifi icon and "Connection Lost" header.
    var isConnectionError: Bool = false
    var generationTimeSeconds: Double? = nil
    var contentChunks: [ContentChunk] = []
    var thinkingChunks: [ThinkingChunk] = []
    var webSearchState: WebSearchState? = nil
    var urlFetches: [URLFetchState] = []
    var attachments: [Attachment] = []
    var thinkingDuration: Double? = nil
    var isError: Bool? = nil
    var webSearchBeforeThinking: Bool? = nil
    var annotations: [Annotation]? = nil
    var segments: [MessageSegment]? = nil
    var webSearches: [WebSearchInstance]? = nil
    var toolCalls: [GenUIToolCall] = []
    /// The reply's blocks as the chat service sent them, which the widgets
    /// read their state from.
    var timeline: [JSONValue]? = nil

    init(id: String = UUID().uuidString.lowercased(), role: MessageRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    /// True when this assistant message has at least one tool call whose
    /// widget is not registered on this client. Used to surface the
    /// "interactive component unavailable" notice for forward
    /// compatibility (e.g. a newly-added widget that web supports but
    /// iOS hasn't shipped yet).
    @MainActor var hasUnsupportedGenUI: Bool {
        toolCalls.contains { GenUIRegistry.widget(named: $0.name) == nil }
    }

    /// Resolution for the given tool-call id, read from the timeline.
    func genUIResolution(for toolCallId: String) -> GenUIResolution? {
        guard let timeline else { return nil }
        return TimelineToolCalls.resolution(in: timeline, toolCallId: toolCallId)
    }

    static let longMessageAttachmentThreshold = 1200
    var shouldDisplayAsAttachment: Bool {
        role == .user && content.count >= Message.longMessageAttachmentThreshold
    }

    var hasVisibleAssistantContent: Bool {
        role == .assistant && (
            !content.isEmpty
                || thoughts?.isEmpty == false
                || segments?.isEmpty == false
                || webSearches?.isEmpty == false
                || webSearchState != nil
                || !urlFetches.isEmpty
                || !toolCalls.isEmpty
                || annotations?.isEmpty == false
                || timeline?.isEmpty == false
        )
    }

    /// True when a continuation request would show the model something to
    /// resume: text or tool calls. Thoughts alone are not always sent back.
    var hasContinuableResponse: Bool {
        role == .assistant && (!content.isEmpty || !toolCalls.isEmpty)
    }
}

// MARK: - Haptic Feedback

/// Utility for handling haptic feedback in chat interactions
enum HapticFeedback {
    /// Available haptic feedback types for chat interactions
    enum FeedbackType {
        case error
        case success
    }

    /// Triggers haptic feedback of specified type if enabled in settings
    static func trigger(_ type: FeedbackType) {
        let hapticEnabled = UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.hapticFeedbackEnabled) as? Bool ?? true
        guard hapticEnabled else { return }

        let generator = UINotificationFeedbackGenerator()
        switch type {
        case .error:
            generator.notificationOccurred(.error)
        case .success:
            generator.notificationOccurred(.success)
        }
    }
}


// MARK: - Rate Limit Info

/// The account's quota as the views show it.
struct RateLimitInfo: Equatable {
    /// Distinguishes the anonymous/free-tier daily request limit from the
    /// per-account hourly usage cap that subscribers hit. Both flow through the
    /// same channel but render differently: the hourly cap is transient, does
    /// not block input, and offers no upgrade (the user already subscribes).
    enum Kind {
        case freeDaily
        case hourly
    }

    var maxRequests: Int
    var remaining: Int
    var resetsAt: String
    var maxTokens: Int? = nil
    var tokensUsed: Int? = nil
    var tokensRemaining: Int? = nil
    var kind: Kind = .freeDaily

    /// The quota the chat service reports, when it reports one.
    init?(_ limit: HarnessRateLimit) {
        guard let kind = limit.kind else { return nil }
        self.kind = kind == .hourly ? .hourly : .freeDaily
        maxRequests = limit.maxRequests ?? 0
        remaining = limit.remaining ?? 0
        resetsAt = limit.resetsAt ?? ""
        if let input = limit.inputTokens {
            maxTokens = input.max
            tokensUsed = input.used
            tokensRemaining = input.remaining
        }
    }
}
