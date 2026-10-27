import Foundation

/// A whole chat in the format the harness stores it in sync, a chat on this
/// device is kept in, and a device run's final event returns. The client
/// keeps every member, including members it does not know, and sends the
/// record back as it was returned; it changes only the members the user
/// changes, and the attachment bytes it holds for the harness.
struct StoredThread: Equatable, Sendable {
    /// The user's settings of a chat, which a change through the harness
    /// keeps when a run's thread is stored meanwhile.
    static let userSettings = ["title", "titleState", "model", "presetId", "webSearchEnabled"]

    private(set) var fields: [String: JSONValue]

    init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    /// A record as JSON, which must hold a list of messages.
    init?(json object: [String: Any]) {
        guard object["messages"] is [Any] else { return nil }
        fields = object.mapValues(JSONValue.init(any:))
    }

    init?(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(json: object)
    }

    /// The copy of a new chat this device lists until the harness returns
    /// the chat its first turn made.
    static func new(id: String, createdAt: Date = Date()) -> StoredThread {
        let created = JSONValue.string(Self.timestamp(createdAt))
        return StoredThread(fields: [
            "id": .string(id),
            "title": .string(Constants.Harness.placeholderTitle),
            "titleState": .string(Components.Schemas.TitleState.placeholder.rawValue),
            "createdAt": created,
            "updatedAt": created,
            "model": .string(""),
            "projectId": .null,
            "presetId": .null,
            "pinned": .bool(false),
            "webSearchEnabled": .bool(true),
            "messages": .array([]),
            "activeRun": .null,
        ])
    }

    var json: [String: Any] {
        fields.mapValues(\.any)
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// The record as the protocol describes the members this client reads.
    /// Members the client does not know are not in it.
    var record: Components.Schemas.ThreadRecord? {
        try? Components.Schemas.ThreadRecord(jsonObject: json)
    }

    subscript(member: String) -> JSONValue? {
        get { fields[member] }
        set { fields[member] = newValue }
    }

    var id: String {
        get { fields["id"]?.stringValue ?? "" }
        set { fields["id"] = .string(newValue) }
    }

    var title: String { fields["title"]?.stringValue ?? "" }
    var titleState: Components.Schemas.TitleState {
        fields["titleState"]?.stringValue.flatMap(Components.Schemas.TitleState.init(rawValue:)) ?? .placeholder
    }
    var createdAt: String? { fields["createdAt"]?.stringValue }
    var updatedAt: String? {
        get { fields["updatedAt"]?.stringValue }
        set { fields["updatedAt"] = newValue.map(JSONValue.string) ?? .null }
    }
    var model: String { fields["model"]?.stringValue ?? "" }
    var presetId: String? { fields["presetId"]?.stringValue }
    var webSearchEnabled: Bool { fields["webSearchEnabled"]?.boolValue ?? true }
    var flagged: Bool { fields["flagged"]?.boolValue ?? false }
    /// Absent for a record this device made before its first run, or an
    /// older client kept; present once the harness returned the record.
    var recordVersion: Int? {
        if case .number(let version) = fields["recordVersion"] ?? .null { return Int(version) }
        return nil
    }

    var messages: [JSONValue] {
        get { fields["messages"]?.arrayValue ?? [] }
        set { fields["messages"] = .array(newValue) }
    }

    var messageRecords: [Components.Schemas.MessageRecord] {
        messages.compactMap { try? Components.Schemas.MessageRecord(jsonValue: $0) }
    }

    /// When the chat was last active: its latest message, or else its
    /// creation.
    var activityAt: String {
        var latest = createdAt.flatMap(ChatAccessCache.date(of:)) ?? Date(timeIntervalSince1970: 0)
        for message in messages {
            if let at = message.objectValue?["createdAt"]?.stringValue.flatMap(ChatAccessCache.date(of:)), at > latest { latest = at }
        }
        return Self.timestamp(latest)
    }

    /// The chat as a list shows it. One on this device belongs to no
    /// project, is no favorite, and has no run the harness could report.
    var summary: ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            titleState: titleState,
            createdAt: createdAt,
            updatedAt: updatedAt,
            activityAt: activityAt,
            projectId: nil,
            model: model,
            webSearchEnabled: webSearchEnabled,
            pinned: false,
            contextUsage: record?.contextUsage.map {
                ThreadSummary.ContextUsagePayload(usedTokens: $0.usedTokens, limitTokens: $0.limitTokens, percentage: $0.percentage)
            },
            activeRun: nil,
            messageCount: messages.count,
            flagged: flagged ? true : nil
        )
    }

    /// The chat as the view shows it, without the image bytes and page
    /// images its attachments hold.
    var window: ThreadWindow {
        let summary = summary
        return ThreadWindow(
            id: summary.id,
            title: summary.title,
            titleState: summary.titleState,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            activityAt: summary.activityAt,
            projectId: nil,
            model: summary.model,
            webSearchEnabled: summary.webSearchEnabled,
            pinned: false,
            contextUsage: summary.contextUsage.map {
                ThreadWindow.ContextUsagePayload(usedTokens: $0.usedTokens, limitTokens: $0.limitTokens, percentage: $0.percentage)
            },
            activeRun: nil,
            messageCount: summary.messageCount,
            flagged: summary.flagged,
            revision: "",
            presetId: presetId,
            messages: messageRecords.map(HarnessMessage.init(shown:)),
            hasOlder: false
        )
    }

    /// Takes the settings named from another copy of the chat.
    mutating func take(_ settings: [String], from other: StoredThread) {
        for setting in settings where Self.userSettings.contains(setting) {
            fields[setting] = other.fields[setting] ?? .null
        }
    }

    /// The settings that differ from another copy of the chat.
    func changedSettings(from other: StoredThread) -> [String] {
        Self.userSettings.filter { fields[$0] != other.fields[$0] }
    }

    /// The attachments of every message, by id.
    var attachments: [Components.Schemas.Attachment] {
        messageRecords.flatMap { $0.attachments ?? [] }
    }

    /// The copy of the thread a share carries: image thumbnails and document
    /// text, never image bytes or page images.
    func forShare() -> StoredThread {
        var shared = self
        shared.messages = messages.map { message in
            guard var object = message.objectValue, let attachments = object["attachments"]?.arrayValue else { return message }
            object["attachments"] = .array(attachments.map { attachment in
                guard var fields = attachment.objectValue else { return attachment }
                let text = Self.documentText(fields)
                fields["base64"] = nil
                fields["pages"] = nil
                if let text, !text.isEmpty { fields["textContent"] = .string(text) }
                return .object(fields)
            })
            return .object(object)
        }
        return shared
    }

    /// A document's text as the harness reads a stored one: its extracted
    /// text, or else the text of its pages.
    static func documentText(_ attachment: [String: JSONValue]) -> String? {
        if let text = attachment["textContent"]?.stringValue, !text.isEmpty { return text }
        let pages = attachment["pages"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue }.filter { !$0.isEmpty } ?? []
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        timestamps.string(from: date)
    }
}

/// The images of attachments the harness may leave out of a thread: an
/// image's bytes, and a document's page images by page, which this device
/// holds and puts back.
struct HeldImages: Equatable, Sendable {
    var base64: String?
    var pageImages: [String]?
}

typealias ImagesById = [String: HeldImages]

extension StoredThread {
    /// Records the images the messages' attachments carry, by attachment id.
    static func holdImages(_ attachments: [JSONValue], into held: inout ImagesById) {
        for attachment in attachments {
            guard let fields = attachment.objectValue, let id = fields["id"]?.stringValue else { continue }
            let base64 = fields["base64"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let pages = fields["pages"]?.arrayValue?.map { $0.objectValue?["image"]?.stringValue ?? "" }
            let pageImages = pages?.contains { !$0.isEmpty } == true ? pages : nil
            if base64 != nil || pageImages != nil { held[id] = HeldImages(base64: base64, pageImages: pageImages) }
        }
    }

    var heldImages: ImagesById {
        var held: ImagesById = [:]
        for message in messages { Self.holdImages(message.objectValue?["attachments"]?.arrayValue ?? [], into: &held) }
        return held
    }

    /// Puts back the images this device holds where the thread lacks them.
    mutating func restore(_ held: ImagesById) {
        guard !held.isEmpty else { return }
        messages = messages.map { message in
            guard var object = message.objectValue, let attachments = object["attachments"]?.arrayValue,
                  attachments.contains(where: { held[$0.objectValue?["id"]?.stringValue ?? ""] != nil }) else { return message }
            object["attachments"] = .array(attachments.map { attachment in
                guard var fields = attachment.objectValue, let id = fields["id"]?.stringValue, let kept = held[id] else { return attachment }
                if let base64 = kept.base64, (fields["base64"]?.stringValue ?? "").isEmpty { fields["base64"] = .string(base64) }
                if let pageImages = kept.pageImages, let pages = fields["pages"]?.arrayValue {
                    fields["pages"] = .array(pages.enumerated().map { index, page in
                        guard var page = page.objectValue, index < pageImages.count, !pageImages[index].isEmpty,
                              (page["image"]?.stringValue ?? "").isEmpty else { return page }
                        page["image"] = .string(pageImages[index])
                        return .object(page)
                    })
                }
                return .object(fields)
            })
            return .object(object)
        }
    }
}

/// The file a user picked for an image attachment, kept apart from the chat:
/// the chat holds the copy models read; the original is only shown.
struct AttachmentOriginal: Codable, Equatable, Sendable {
    let base64: String
    let mimeType: String
}

typealias Originals = [String: AttachmentOriginal]

extension JSONValue {
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? Int64(value) : value
        case .string(let value): return value
        case .array(let values): return values.map(\.any)
        case .object(let members): return members.mapValues(\.any)
        }
    }

}

extension Decodable {
    init(jsonValue: JSONValue) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonValue.any, options: [.fragmentsAllowed])
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}

extension HarnessMessage {
    /// A message as the view shows it, from the record a chat on this device
    /// keeps: without its attachments' bytes.
    init(shown record: Components.Schemas.MessageRecord) {
        self.init(
            id: record.id,
            role: record.role,
            createdAt: record.createdAt,
            content: record.content,
            timeline: record.timeline,
            quote: record.quote,
            model: record.model,
            modelDisplayName: record.modelDisplayName,
            isError: record.isError,
            isInterrupted: record.isInterrupted,
            usage: record.usage,
            annotations: record.annotations,
            attachments: record.attachments?.map {
                Components.Schemas.AttachmentView(id: $0.id, kind: $0.kind, fileName: $0.fileName, mimeType: $0.mimeType, size: $0.size, thumbnail: $0.thumbnail, textContent: $0.textContent, description: $0.description)
            }
        )
    }
}
