import Foundation
import OSLog

/// A change to a chat's settings.
struct ThreadPatch: Equatable, Sendable {
    var title: String?
    var model: String?
    var presetId: Nullable<String>?
    var webSearchEnabled: Bool?
    var pinned: Bool?
    var projectId: Nullable<String>?
}

/// What a turn starts a chat with, as the open chat holds it.
struct TurnSettings {
    /// The chat has no turn the harness accepted, or no copy on this device.
    var first: Bool
    var presetId: String?
    var presetChosen: Bool
    var projectId: String?
    var profile: ProfileFields
}

struct PreparedTurn {
    var input: Turn
    /// The input the turn is sent again with to reconnect.
    var resend: Turn
    var run: DeviceRun?
    /// Keeps the message the turn adds until its run returns the thread.
    var keep: ((Components.Schemas.MessageRecord) async -> Void)?
}

/// The chats a run's context comes from for an ask.
struct AskContext {
    var key: String?
    var threadId: String
    var local: Bool?
    var thread: StoredThread?
    var profile: ProfileFields?
}

/// A chat as a store answers with it: its latest messages, and the revision
/// a stored chat is at.
struct ThreadResult: Sendable {
    var window: ThreadWindow
    var revision: String?

    init(window: ThreadWindow) {
        self.window = window
        revision = window.revision.isEmpty ? nil : window.revision
    }
}

/// The changes a store makes to the chat list it belongs to, shown before
/// the list is next read.
@MainActor
protocol ListEdits: AnyObject {
    /// A chat new to the list, as a fork or a chat moved here.
    func add(_ summary: ThreadSummary)
    func replace(_ summary: ThreadSummary)
    func remove(_ threadId: String)
}

/// Where a chat is stored: the harness keeps a chat in the cloud and is
/// named it by id and key; a chat on this device is kept by the app and
/// sent with each turn. Actions go through the open chat's store instead of
/// asking where it lives.
@MainActor
protocol ThreadStore: AnyObject {
    /// Turns carry the chat itself rather than the content key.
    var local: Bool { get }
    func get(_ threadId: String) async throws -> ThreadResult?
    /// The messages before `before` that the view does not show yet.
    func older(_ threadId: String, before: String?) async throws -> (messages: [HarnessMessage], hasOlder: Bool)
    func update(_ threadId: String, _ patch: ThreadPatch) async throws -> ThreadSummary?
    func remove(_ threadId: String) async throws
    /// Copies the chat through a message into a new chat, and names it.
    func fork(_ threadId: String, messageId: String) async throws -> String?
    func deleteMessage(_ threadId: String, messageId: String) async throws -> ThreadResult?
    func editReply(_ threadId: String, messageId: String, content: String) async throws -> ThreadResult?
    func share(_ threadId: String) async throws -> String
    /// The audio of a message read aloud, as one stream.
    func speech(_ threadId: String, messageId: String) async throws -> HarnessResponse
    /// The key a turn and its run carry; reading it may refuse.
    func runKey() throws -> String?
    /// A turn of the chat: the fields every turn has, and the action's own.
    func prepareTurn(_ threadId: String, defaults: Turn, fields: TurnFields, key: String?, settings: TurnSettings) async throws -> PreparedTurn?
    /// A run of the chat that may still be live, and the instance holding it.
    func liveRun(_ thread: ThreadWindow) -> RunReceipt?
    func follow(_ threadId: String, runId: String) async throws -> (body: RunBody, device: DeviceRun?)
    func askContext(_ threadId: String, profile: ProfileFields) async throws -> AskContext
    func documentText(_ threadId: String?, attachmentId: String) async throws -> String
    /// An image's bytes: the file the user picked while this app holds it,
    /// or the copy the chat keeps, named by the type the attachment holds.
    func image(_ threadId: String?, attachmentId: String, mimeType: String?) async throws -> (data: Data, mimeType: String)
}

/// The members of a turn an action sets beyond the defaults.
struct TurnFields: Sendable {
    var kind: Turn.Kind?
    var content: String?
    var quote: String?
    var messageId: String?
    var toolCallId: String?
    var attachments: [SentAttachment]?
    var options: TurnOptions?

    func applied(to turn: Turn) -> Turn {
        var turn = turn
        if let kind { turn.kind = kind }
        if let content { turn.content = content }
        if let quote { turn.quote = quote }
        if let messageId { turn.messageId = messageId }
        if let toolCallId { turn.toolCallId = toolCallId }
        if let attachments { turn.attachments = attachments }
        if let options { turn.options = options }
        return turn
    }
}

/// What the open chat's view reads of its attachments: the image bytes a
/// chat on this device holds, uploads the chat does not store yet, the files
/// the user picked for them, and the document texts read so far. Clearing
/// it moves the view to another chat.
@MainActor
final class OpenAttachments {
    private(set) var images: [String: (base64: String, mimeType: String)] = [:]
    private(set) var uploads: [String: Components.Schemas.Attachment] = [:]
    private(set) var originals: Originals = [:]
    private var texts: [String: Task<String, Error>] = [:]

    /// The originals of the images of a turn, by attachment id.
    func originalsOf(_ attachments: [Components.Schemas.Attachment]) -> Originals {
        var found: Originals = [:]
        for attachment in attachments {
            if let original = originals[attachment.id] { found[attachment.id] = original }
        }
        return found
    }

    func keepOriginal(_ id: String, _ original: AttachmentOriginal) {
        originals[id] = original
    }

    func remember(_ attachments: [Components.Schemas.Attachment]) {
        for attachment in attachments {
            if let base64 = attachment.base64, !base64.isEmpty { images[attachment.id] = (base64, attachment.mimeType) }
        }
    }

    func rememberThread(_ thread: StoredThread) {
        for (id, held) in thread.heldImages {
            if let base64 = held.base64 { images[id] = (base64, thread.attachmentFields(id)?["mimeType"]?.stringValue ?? "image/jpeg") }
        }
    }

    /// The attachments a turn sends stay readable until the chat stores
    /// them.
    func rememberSent(_ attachments: [SentAttachment]?) {
        let sent = (attachments ?? []).compactMap(\.uploaded)
        for attachment in sent { uploads[attachment.id] = attachment }
        remember(sent)
    }

    /// A document's text, read once; a failed read is tried again next time.
    func text(_ id: String, read: @escaping () async throws -> String) async throws -> String {
        if let cached = texts[id] { return try await cached.value }
        let reading = Task { try await read() }
        texts[id] = reading
        do {
            return try await reading.value
        } catch {
            if texts[id] == reading { texts[id] = nil }
            throw error
        }
    }

    func clear() {
        images = [:]
        uploads = [:]
        originals = [:]
        texts = [:]
    }
}

private func summaryOf(_ window: ThreadWindow) -> ThreadSummary {
    ThreadSummary(
        id: window.id, title: window.title, titleState: window.titleState, createdAt: window.createdAt, updatedAt: window.updatedAt,
        activityAt: window.activityAt, projectId: window.projectId, model: window.model, webSearchEnabled: window.webSearchEnabled,
        pinned: window.pinned,
        contextUsage: window.contextUsage.map { ThreadSummary.ContextUsagePayload(usedTokens: $0.usedTokens, limitTokens: $0.limitTokens, percentage: $0.percentage) },
        activeRun: window.activeRun.map { ThreadSummary.ActiveRunPayload(runId: $0.runId, expiresAt: $0.expiresAt, instance: $0.instance) },
        messageCount: window.messageCount, flagged: window.flagged
    )
}

private struct ShareReply: Decodable {
    let url: String
}

private struct DeviceThreadReply: Decodable {
    let thread: RawJSON?
}

/// The chats the harness stores for an account.
@MainActor
final class CloudThreads: ThreadStore {
    let local = false
    private let account: HarnessAccount
    private let list: ListEdits
    private let attachments: OpenAttachments
    /// The change whose answer each chat is listed from.
    private var latestListed: [String: Int] = [:]
    private var updates = 0

    init(account: HarnessAccount, list: ListEdits, attachments: OpenAttachments) {
        self.account = account
        self.list = list
        self.attachments = attachments
    }

    func get(_ threadId: String) async throws -> ThreadResult? {
        ThreadResult(window: try await account.post(.get, ThreadRequest(id: threadId)))
    }

    func older(_ threadId: String, before: String?) async throws -> (messages: [HarnessMessage], hasOlder: Bool) {
        let window: ThreadWindow = try await account.post(.get, ThreadPageRequest(id: threadId, before: before))
        return (window.messages, window.hasOlder)
    }

    /// The latest change answered lists the chat; one asked earlier and
    /// answered later does not list it as it was before.
    func update(_ threadId: String, _ patch: ThreadPatch) async throws -> ThreadSummary? {
        updates += 1
        let update = updates
        let summary: ThreadSummary = try await account.post(.update, ThreadUpdateRequest(
            id: threadId, title: patch.title, model: patch.model, presetId: patch.presetId,
            webSearchEnabled: patch.webSearchEnabled, pinned: patch.pinned, projectId: patch.projectId
        ))
        if update > latestListed[threadId, default: 0] {
            latestListed[threadId] = update
            list.replace(summary)
        }
        return summary
    }

    func remove(_ threadId: String) async throws {
        let _: RawJSON = try await account.post(.delete, DeleteRequest(id: threadId))
        list.remove(threadId)
    }

    func fork(_ threadId: String, messageId: String) async throws -> String? {
        let forked: ThreadSummary = try await account.post(.fork, MessageRequest(threadId: threadId, messageId: messageId))
        list.add(forked)
        return forked.id
    }

    /// The harness changes a stored chat's message and answers with its
    /// latest window.
    private func change(_ route: HarnessRoute, _ request: MessageRequest) async throws -> ThreadResult {
        let window: ThreadWindow = try await account.post(route, request)
        list.replace(summaryOf(window))
        return ThreadResult(window: window)
    }

    func deleteMessage(_ threadId: String, messageId: String) async throws -> ThreadResult? {
        try await change(.messageDelete, MessageRequest(threadId: threadId, messageId: messageId))
    }

    func editReply(_ threadId: String, messageId: String, content: String) async throws -> ThreadResult? {
        try await change(.messageUpdate, MessageRequest(threadId: threadId, messageId: messageId, content: content))
    }

    func share(_ threadId: String) async throws -> String {
        let reply: ShareReply = try await account.post(.share, ShareRequest(threadId: threadId))
        return reply.url
    }

    func speech(_ threadId: String, messageId: String) async throws -> HarnessResponse {
        try await account.stream(.speech, SpeechRequest(threadId: threadId, messageId: messageId))
    }

    func runKey() throws -> String? {
        try account.key()
    }

    func prepareTurn(_ threadId: String, defaults: Turn, fields: TurnFields, key: String?, settings: TurnSettings) async throws -> PreparedTurn? {
        var input = fields.applied(to: defaults)
        input.key = key
        input.threadId = threadId
        // The harness starts a stored chat with the default prompt when its
        // first turn names none, and keeps a first turn's choice, null too.
        input.projectId = settings.first ? settings.projectId.map(Nullable.value) : nil
        input.presetId = settings.first && settings.presetChosen ? Nullable(settings.presetId) : nil
        return PreparedTurn(input: input, resend: input.resend, run: nil, keep: nil)
    }

    func liveRun(_ thread: ThreadWindow) -> RunReceipt? {
        thread.activeRun.map { RunReceipt(threadId: thread.id, runId: $0.runId, instance: $0.instance) }
    }

    func follow(_ threadId: String, runId: String) async throws -> (body: RunBody, device: DeviceRun?) {
        (RunBody(key: try account.key(), threadId: threadId, runId: runId), nil)
    }

    func askContext(_ threadId: String, profile: ProfileFields) async throws -> AskContext {
        AskContext(key: try account.key(), threadId: threadId)
    }

    private func download(_ threadId: String?, _ attachmentId: String) async throws -> Data {
        try await account.download(.attachmentGet, AttachmentRequest(id: attachmentId, threadId: threadId))
    }

    func documentText(_ threadId: String?, attachmentId: String) async throws -> String {
        try await attachments.text(attachmentId) { [self] in
            String(decoding: try await download(threadId, attachmentId), as: UTF8.self)
        }
    }

    func image(_ threadId: String?, attachmentId: String, mimeType: String?) async throws -> (data: Data, mimeType: String) {
        if let original = attachments.originals[attachmentId], let data = Data(base64Encoded: original.base64) {
            return (data, original.mimeType)
        }
        return (try await download(threadId, attachmentId), mimeType ?? Constants.Attachments.defaultImageMimeType)
    }
}

/// The chats this device keeps: in encrypted files for an account, in memory
/// for a signed-out caller, or in memory for a temporary chat. Each turn
/// carries the chat, and a run's final event returns it.
@MainActor
final class DeviceThreads: ThreadStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    let local = true
    private let account: HarnessAccount
    let store: LocalThreadStore
    private let controller: RunController
    private let attachments: OpenAttachments
    private let list: ListEdits
    /// The store holds a new chat now, so its route can open it.
    private let saved: @MainActor (String) -> Void

    init(account: HarnessAccount, store: LocalThreadStore, controller: RunController, attachments: OpenAttachments, list: ListEdits, saved: @escaping @MainActor (String) -> Void) {
        self.account = account
        self.store = store
        self.controller = controller
        self.attachments = attachments
        self.list = list
        self.saved = saved
    }

    private static func notOnDevice(_ what: String) -> HarnessError {
        HarnessError(code: HarnessErrorCode.threadNotFound, message: "This \(what) is not stored on this device.", action: .stop)
    }

    /// The chat as this device stores it, or an empty one.
    private func transcript(_ threadId: String) async throws -> StoredThread {
        try await store.get(threadId) ?? StoredThread.new(id: threadId)
    }

    /// The harness applies an operation to the chat this device sends it.
    /// The chat it answers with keeps the images this device holds where the
    /// harness left them out.
    private func request(_ route: HarnessRoute, _ sent: StoredThread, _ body: some Encodable) async throws -> StoredThread {
        let reply: DeviceThreadReply = try await account.post(route, body, keyless: true)
        guard let data = reply.thread?.data, var thread = StoredThread(data: data) else {
            throw HarnessError(code: HarnessErrorCode.upstreamRefused, message: "The chat service returned an invalid chat.", action: .retry)
        }
        thread.restore(sent.heldImages)
        return thread
    }

    /// Stores the changed chat in place of the copy it was made from. When a
    /// run stored its thread meanwhile, the run's thread keeps its messages
    /// and takes the settings the change made; a change of messages is
    /// dropped.
    private func change(_ threadId: String, _ route: HarnessRoute, _ body: (StoredThread) -> some Encodable) async throws -> StoredThread? {
        guard let sent = try await store.get(threadId) else { return nil }
        let changed = try await request(route, sent, body(sent))
        let settings = changed.changedSettings(from: sent)
        if !settings.isEmpty { controller.settingsChanged(threadId: threadId, settings) }
        return try await store.update(threadId, originals: [:]) { current in
            guard let current else { return nil }
            if current == sent {
                var replaced = changed
                replaced.id = threadId
                return replaced
            }
            guard route == .update else { return nil }
            var kept = current
            kept.take(settings, from: changed)
            return kept
        }
    }

    func get(_ threadId: String) async throws -> ThreadResult? {
        guard let thread = try await store.get(threadId) else { return nil }
        attachments.rememberThread(thread)
        return ThreadResult(window: thread.window)
    }

    /// A run's window of a chat on this device starts later than the
    /// device's copy, which holds the rest.
    func older(_ threadId: String, before: String?) async throws -> (messages: [HarnessMessage], hasOlder: Bool) {
        let messages = try await store.get(threadId)?.window.messages ?? []
        let index = messages.firstIndex { $0.id == before } ?? 0
        return (Array(messages[..<index]), false)
    }

    /// An update may apply a saved prompt, which the profile holds. A chat on
    /// this device belongs to no project and is no favorite.
    func update(_ threadId: String, _ patch: ThreadPatch) async throws -> ThreadSummary? {
        let profile = account.profile
        let changed = try await change(threadId, .update) { sent in
            ThreadUpdateRequest(
                id: threadId, title: patch.title, model: patch.model, presetId: patch.presetId, webSearchEnabled: patch.webSearchEnabled,
                local: true, thread: sent, profile: ProfileFieldsInput(profile)
            )
        }
        guard let summary = changed?.summary else { return nil }
        list.replace(summary)
        return summary
    }

    func remove(_ threadId: String) async throws {
        try await store.delete(threadId)
        list.remove(threadId)
    }

    /// The harness makes the fork, a new chat under an id it chooses, which
    /// this device stores beside the chat it came from.
    func fork(_ threadId: String, messageId: String) async throws -> String? {
        guard let source = try await store.get(threadId) else { return nil }
        let forked = try await request(.fork, source, MessageRequest(threadId: threadId, messageId: messageId, local: true, thread: source))
        let originals = try await store.originals(threadId, attachmentIds: forked.attachments.map(\.id))
        guard let stored = try await store.add(forked, originals: originals) else { return nil }
        list.add(stored.summary)
        return stored.id
    }

    func deleteMessage(_ threadId: String, messageId: String) async throws -> ThreadResult? {
        let changed = try await change(threadId, .messageDelete) { sent in
            MessageRequest(threadId: threadId, messageId: messageId, local: true, thread: sent)
        }
        return changed.map { ThreadResult(window: $0.window) }
    }

    func editReply(_ threadId: String, messageId: String, content: String) async throws -> ThreadResult? {
        let changed = try await change(threadId, .messageUpdate) { sent in
            MessageRequest(threadId: threadId, messageId: messageId, content: content, local: true, thread: sent)
        }
        return changed.map { ThreadResult(window: $0.window) }
    }

    /// A chat kept on this device is shared from its own copy, which the
    /// harness seals without storing it.
    func share(_ threadId: String) async throws -> String {
        let reply: ShareReply = try await account.post(.share, ShareRequest(threadId: threadId, local: true, thread: try await transcript(threadId).forShare()), keyless: true)
        return reply.url
    }

    /// The harness reads a message of the chat this device sends it.
    func speech(_ threadId: String, messageId: String) async throws -> HarnessResponse {
        guard let thread = try await store.get(threadId) else { throw Self.notOnDevice("chat") }
        return try await account.stream(.speech, SpeechRequest(messageId: messageId, local: true, thread: thread), keyless: true)
    }

    func runKey() throws -> String? { nil }

    /// A turn carries the thread as stored and the profile instead of the
    /// content key, which it never uses. The harness makes a new chat from
    /// its first turn, as it does a stored one.
    func prepareTurn(_ threadId: String, defaults: Turn, fields: TurnFields, key: String?, settings: TurnSettings) async throws -> PreparedTurn? {
        let run = DeviceRun(threadId: threadId, store: store, since: controller.tick())
        controller.begin(run)
        let shown = controller.track()
        let stored: StoredThread?
        do {
            stored = try await store.get(threadId)
        } catch {
            controller.settle(run)
            throw error
        }
        guard shown() else { return nil }
        var input = fields.applied(to: defaults)
        input.thread = stored
        input.presetId = settings.first && settings.presetChosen ? Nullable(settings.presetId) : nil
        input.threadId = threadId
        input.local = true
        input.profile = ProfileFieldsInput(settings.profile)
        let base = stored ?? StoredThread.new(id: threadId)
        let sent = (fields.attachments ?? []).compactMap(\.uploaded)
        var held = base.heldImages
        StoredThread.holdImages(sent.compactMap { try? JSONValue(any: $0.jsonObject()) }, into: &held)
        run.images = held
        run.originals = attachments.originalsOf(sent)
        let store = store
        let saved = saved
        return PreparedTurn(input: input, resend: input, run: run) { message in
            // The chat keeps the message until the run returns the thread, so
            // a new chat is listed from its first message.
            do {
                let messageValue = JSONValue(any: try message.jsonObject())
                let kept = try await store.update(threadId, originals: run.originals) { current in
                    var next = current ?? base
                    next.messages.append(messageValue)
                    next.updatedAt = message.createdAt
                    return next
                }
                if kept != nil { saved(threadId) }
            } catch {
                Self.logger.error("Failed to keep a sent message on this device: \(error, privacy: .public)")
            }
        }
    }

    /// A run this app started, or one a relaunched app left behind.
    func liveRun(_ thread: ThreadWindow) -> RunReceipt? {
        if let run = controller.deviceRuns[thread.id]?.run { return run }
        if let receipt = controller.receipt(), receipt.threadId == thread.id { return receipt }
        return nil
    }

    func follow(_ threadId: String, runId: String) async throws -> (body: RunBody, device: DeviceRun?) {
        let device: DeviceRun
        if let running = controller.deviceRuns[threadId] {
            device = running
        } else {
            var held = try await transcript(threadId).heldImages
            StoredThread.holdImages(attachments.uploads.values.compactMap { try? JSONValue(any: $0.jsonObject()) }, into: &held)
            device = DeviceRun(threadId: threadId, store: store, images: held, since: controller.tick())
        }
        return (RunBody(key: nil, threadId: threadId, runId: runId), device)
    }

    func askContext(_ threadId: String, profile: ProfileFields) async throws -> AskContext {
        AskContext(threadId: threadId, local: true, thread: try await store.get(threadId), profile: profile)
    }

    /// A chat on this device keeps a document's text in its descriptor.
    func documentText(_ threadId: String?, attachmentId: String) async throws -> String {
        try await attachments.text(attachmentId) { [self] in
            var fields = try attachments.uploads[attachmentId].map { JSONValue(any: try $0.jsonObject()).objectValue ?? [:] }
            if fields == nil, let threadId {
                fields = try await store.get(threadId)?.attachmentFields(attachmentId)
            }
            guard let fields else { throw Self.notOnDevice("document") }
            return StoredThread.documentText(fields) ?? ""
        }
    }

    /// The file the user picked when this device keeps it, or else the copy
    /// the chat sends models.
    func image(_ threadId: String?, attachmentId: String, mimeType: String?) async throws -> (data: Data, mimeType: String) {
        var image: (base64: String, mimeType: String)? = attachments.originals[attachmentId].map { ($0.base64, $0.mimeType) }
        if image == nil, let threadId, let original = try await store.originals(threadId, attachmentIds: [attachmentId])[attachmentId] {
            image = (original.base64, original.mimeType)
        }
        if image == nil { image = attachments.images[attachmentId] }
        guard let image, let data = Data(base64Encoded: image.base64) else { throw Self.notOnDevice("image") }
        return (data, image.mimeType)
    }
}

/// A device run's final event carries the whole thread, which this device
/// stores with the images it holds where the harness left them out, and the
/// originals of the images the turn sent. The settings the user changed
/// after the run's turn read the chat keep the user's values.
enum DeviceRunStorage {
    @discardableResult
    static func store(_ run: DeviceRun, event: RunEvent, changedSince: [String]) async throws -> StoredThread? {
        let returned: StoredThread?
        switch event {
        case .runFinished(let finished): returned = finished.thread
        case .runError(let failed): returned = failed.thread
        default: returned = nil
        }
        guard var thread = returned else { return nil }
        thread.id = run.threadId
        let base = thread
        return try await run.store.update(run.threadId, originals: run.originals) { stored in
            var next = base
            var held = stored?.heldImages ?? [:]
            held.merge(run.images) { $1 }
            next.restore(held)
            if let stored { next.take(changedSince, from: stored) }
            return next
        }
    }
}
