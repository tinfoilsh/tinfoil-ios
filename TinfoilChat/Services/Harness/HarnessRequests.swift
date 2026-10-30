import Foundation

/// A member a request sets to null, as where the protocol gives null a
/// meaning, or leaves out.
enum Nullable<Value: Encodable & Equatable & Sendable>: Encodable, Equatable, Sendable {
    case null
    case value(Value)

    init(_ value: Value?) {
        self = value.map(Nullable.value) ?? .null
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .value(let value): try container.encode(value)
        }
    }

    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// What a turn asks of the model.
struct TurnOptions: Encodable, Equatable, Sendable {
    var model: String?
    var autoIntelligence: String?
    var reasoningEffort: String?
    var timezone: String?
    var thinking: Bool?
    var webSearch: Bool?
    var piiCheck: Bool?
    var genUI: Bool?
    var cacheSecret: String?
}

/// An upload's attachment as a turn sends it back, or the id alone of one
/// the chat already holds.
enum SentAttachment: Encodable, Equatable, Sendable {
    case uploaded(Components.Schemas.Attachment)
    case held(id: String)

    var id: String {
        switch self {
        case .uploaded(let attachment): return attachment.id
        case .held(let id): return id
        }
    }

    var uploaded: Components.Schemas.Attachment? {
        if case .uploaded(let attachment) = self { return attachment }
        return nil
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .uploaded(let attachment): try attachment.encode(to: encoder)
        case .held(let id): try ["id": id].encode(to: encoder)
        }
    }
}

/// One user action on a chat, which its run carries out.
struct Turn: Encodable, Equatable, Sendable {
    enum Kind: String, Encodable, Sendable {
        case send, edit, regenerate, `continue`, retry, retryToolCall, ask
    }

    var key: String?
    var clientRequestId: String
    var threadId: String
    var kind: Kind = .send
    var ephemeral: Bool?
    var local: Bool?
    /// A device chat as stored, sent back whole.
    var thread: StoredThread?
    var profile: ProfileFieldsInput?
    var projectId: Nullable<String>?
    var presetId: Nullable<String>?
    var content: String?
    var quote: String?
    var messageId: String?
    var toolCallId: String?
    var attachments: [SentAttachment]?
    var widgets: [String]?
    var options: TurnOptions?

    private enum CodingKeys: String, CodingKey {
        case key, clientRequestId, threadId, kind, ephemeral, local, thread, profile, projectId, presetId
        case content, quote, messageId, toolCallId, attachments, widgets, options
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(clientRequestId, forKey: .clientRequestId)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(ephemeral, forKey: .ephemeral)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(presetId, forKey: .presetId)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(quote, forKey: .quote)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(widgets, forKey: .widgets)
        try container.encodeIfPresent(options, forKey: .options)
    }

    /// The turn without its content key, as it is sent again to reconnect;
    /// the key is added again when it is.
    var resend: Turn {
        var copy = self
        copy.key = nil
        return copy
    }
}

/// The settings a device turn carries, as this device holds them.
struct ProfileFieldsInput: Encodable, Equatable, Sendable {
    let fields: [String: JSONValue]

    init(_ fields: ProfileFields) {
        self.fields = fields.mapValues(JSONValue.init(any:))
    }

    func encode(to encoder: any Encoder) throws {
        try JSONObject(fields).encode(to: encoder)
    }
}

/// A run to follow, cancel, or send a queued turn of.
struct RunRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String
    var runId: String?
    var queueId: String?
}

/// A request that names a chat, with the content key when stored.
struct ThreadRequest: Encodable, Equatable, Sendable {
    var key: String?
    var id: String
}

/// A change to a stored chat's settings.
struct ThreadUpdateRequest: Encodable, Equatable, Sendable {
    var key: String?
    var id: String
    var title: String?
    var model: String?
    var presetId: Nullable<String>?
    var webSearchEnabled: Bool?
    var pinned: Bool?
    var projectId: Nullable<String>?
    /// A device chat, sent whole, with the settings the harness applies a
    /// prompt from.
    var local: Bool?
    var thread: StoredThread?
    var profile: ProfileFieldsInput?

    private enum CodingKeys: String, CodingKey {
        case key, id, title, model, presetId, webSearchEnabled, pinned, projectId, local, thread, profile
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(presetId, forKey: .presetId)
        try container.encodeIfPresent(webSearchEnabled, forKey: .webSearchEnabled)
        try container.encodeIfPresent(pinned, forKey: .pinned)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
        try container.encodeIfPresent(profile, forKey: .profile)
    }
}

/// A change to a chat's message: deleting it, editing a reply, or forking
/// the chat at it.
struct MessageRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String
    var messageId: String
    var content: String?
    var local: Bool?
    var thread: StoredThread?

    private enum CodingKeys: String, CodingKey {
        case key, threadId, messageId, content, local, thread
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(messageId, forKey: .messageId)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
    }
}

/// A page of stored chats.
struct ListRequest: Encodable, Equatable, Sendable {
    var key: String?
    var cursor: String?
    var limit: Int?
    var projectId: String?
}

/// A search of stored chats.
struct SearchRequest: Encodable, Equatable, Sendable {
    var key: String?
    var query: String
    var limit: Int?
}

/// The messages of a stored chat before one the view shows.
struct ThreadPageRequest: Encodable, Equatable, Sendable {
    var key: String?
    var id: String
    var before: String?
}

/// A chat to read aloud a message of: stored, or sent whole.
struct SpeechRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String?
    var messageId: String?
    var text: String?
    var local: Bool?
    var thread: StoredThread?

    private enum CodingKeys: String, CodingKey {
        case key, threadId, messageId, text, local, thread
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(threadId, forKey: .threadId)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
    }
}

/// A chat to share: stored, or sent whole.
struct ShareRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String
    var local: Bool?
    var thread: StoredThread?

    private enum CodingKeys: String, CodingKey {
        case key, threadId, local, thread
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(threadId, forKey: .threadId)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
    }
}

/// An attachment to download.
struct AttachmentRequest: Encodable, Equatable, Sendable {
    var key: String?
    var id: String
    var threadId: String?
}

/// Device chats an older client kept, for the harness to convert.
struct UpgradeRequest: Encodable, Sendable {
    var threads: [JSONObject]
}

/// A stored chat to move to this device, or one on this device to store.
struct TransferRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String
    var thread: StoredThread?

    private enum CodingKeys: String, CodingKey {
        case key, threadId, thread
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(threadId, forKey: .threadId)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
    }
}

/// A stored chat to delete, at the revision this client showed.
struct DeleteRequest: Encodable, Equatable, Sendable {
    var key: String?
    var id: String
    var revision: String?
}
