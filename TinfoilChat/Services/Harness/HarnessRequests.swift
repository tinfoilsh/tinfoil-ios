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
    var research: Bool?
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
        case send, edit, regenerate, `continue`, retry, retryToolCall, ask, compact
    }

    var key: String?
    var clientRequestId: String
    var threadId: String
    var kind: Kind = .send
    var ephemeral: Bool?
    var local: Bool?
    /// A device chat as stored, sent back whole or from its latest
    /// compaction marker on.
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
    /// A compaction, or a retry that compacts again, summarizes the chat's
    /// latest exchange too.
    var compactLatest: Bool?
    var options: TurnOptions?

    private enum CodingKeys: String, CodingKey {
        case key, clientRequestId, threadId, kind, ephemeral, local, thread, profile, projectId, presetId
        case content, quote, messageId, toolCallId, attachments, widgets, compactLatest, options
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
        try container.encodeIfPresent(compactLatest, forKey: .compactLatest)
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

/// Changes to saved prompts and favorites by id, which the harness applies
/// to the profile as it stores it.
struct PromptEdits {
    /// Prompts to add, each replacing the one with its id where it stands.
    var save: [ProfileFields] = []
    /// Changes to prompts, each setting the members it names on the prompt
    /// with its id, and clearing those it names as null.
    var update: [ProfileFields] = []
    /// Prompts to remove, which are then no longer favorites or the default.
    var delete: [String] = []
    var addFavorites: [String] = []
    var removeFavorites: [String] = []

    /// The request's members, without the edits it makes none of.
    var body: JSONObject {
        var members: [String: Any] = [:]
        if !save.isEmpty { members["savePromptPresets"] = save }
        if !update.isEmpty { members["updatePromptPresets"] = update }
        if !delete.isEmpty { members["deletePromptPresetIds"] = delete }
        if !addFavorites.isEmpty { members["addFavoritePromptPresetIds"] = addFavorites }
        if !removeFavorites.isEmpty { members["removeFavoritePromptPresetIds"] = removeFavorites }
        return JSONObject(members)
    }

    /// The fields the edits change in a profile, as the harness applies
    /// them, so a change shows before the harness answers.
    func applied(to profile: ProfileFields) -> ProfileFields {
        var patch: ProfileFields = [:]
        if !save.isEmpty || !update.isEmpty || !delete.isEmpty {
            var presets = profile["customPromptPresets"] as? [Any] ?? []
            for preset in save {
                if let index = presets.firstIndex(where: { Self.id(of: $0) == preset["id"] as? String }) {
                    presets[index] = preset
                } else {
                    presets.append(preset)
                }
            }
            // A prompt another device deleted stays deleted.
            for change in update {
                guard let index = presets.firstIndex(where: { Self.id(of: $0) == change["id"] as? String }),
                      var preset = presets[index] as? ProfileFields else { continue }
                for (name, value) in change {
                    if value is NSNull { preset.removeValue(forKey: name) } else { preset[name] = value }
                }
                presets[index] = preset
            }
            patch["customPromptPresets"] = presets.filter { preset in
                guard let id = Self.id(of: preset) else { return true }
                return !delete.contains(id)
            }
        }
        if !delete.isEmpty || !addFavorites.isEmpty || !removeFavorites.isEmpty {
            var favorites = (profile["favoritePromptPresetIds"] as? [String] ?? []).filter { !delete.contains($0) && !removeFavorites.contains($0) }
            for id in addFavorites where !favorites.contains(id) && !delete.contains(id) {
                favorites.append(id)
            }
            patch["favoritePromptPresetIds"] = favorites
        }
        if let id = profile["defaultPromptPresetId"] as? String, delete.contains(id) {
            patch["defaultPromptPresetId"] = ""
        }
        return patch
    }

    private static func id(of preset: Any) -> String? {
        (preset as? ProfileFields)?["id"] as? String
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
    /// A device chat, sent whole or from its latest compaction marker on,
    /// with the settings the harness applies a prompt from.
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

/// The options picked in a questions widget of a reply, by question id:
/// each question named takes its options, or is left unanswered when null,
/// and the others keep their answers.
struct AnswerRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String
    var messageId: String
    var toolCallId: String
    var answers: [String: Nullable<[String]>]
    var local: Bool?
    var thread: StoredThread?
    var profile: ProfileFieldsInput?

    private enum CodingKeys: String, CodingKey {
        case key, threadId, messageId, toolCallId, answers, local, thread, profile
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(answers, forKey: .answers)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
        try container.encodeIfPresent(profile, forKey: .profile)
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

/// A chat to read aloud a message of: stored, or sent with the request.
struct SpeechRequest: Encodable, Equatable, Sendable {
    var key: String?
    var threadId: String?
    var messageId: String?
    var text: String?
    var local: Bool?
    var thread: StoredThread?
    /// How fast the audio plays, absent at the voice's own speed.
    var speed: Double?

    private enum CodingKeys: String, CodingKey {
        case key, threadId, messageId, text, local, thread, speed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(threadId, forKey: .threadId)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(thread.map { JSONObject($0.fields) }, forKey: .thread)
        try container.encodeIfPresent(speed, forKey: .speed)
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

/// A stored chat to delete, at the revision this client showed, or a chat
/// this device deleted, which the harness drops what it keeps of.
struct DeleteRequest: Encodable, Equatable, Sendable {
    var key: String?
    var id: String
    var revision: String?
    var local: Bool?
}

/// Every chat this device deleted, which the harness drops what it keeps of.
struct DeleteAllRequest: Encodable, Equatable, Sendable {
    var local: Bool
}
