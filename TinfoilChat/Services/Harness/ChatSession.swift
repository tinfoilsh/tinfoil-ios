import Combine
import Foundation
import OSLog

/// The chat the view shows, and how it is stored.
struct OpenChat: Equatable {
    var id: String?
    var temporary = false
    /// The chat is kept on this device rather than by the harness.
    var local: Bool
    /// A new chat the harness has not accepted a turn of, or whose copy on
    /// this device is not written yet.
    var unsaved: String?
    var loadingId: String?
    var failedId: String?
    var notFound = false
    var model = ""
    var failure: HarnessErrorBody?
    /// The user chose the chat's prompt, or the chat was opened with one.
    var presetChosen = false
    var chosenPresetId: String?
    var modelChosen = false
    var webSearch: Bool?
    var projectId: String?

    var onDevice: Bool { local || temporary }
}

/// What a new chat's saved prompt chooses and the user did not change, which
/// the composer shows until the first turn, when the harness applies it.
struct PresetChoice: Equatable {
    var model: String?
    var webSearchEnabled: Bool?
}

enum OpenChatResult: Equatable {
    case opened
    case notFound
    case superseded
}

/// Why the open chat cannot take a turn yet.
enum SendBlock: Equatable {
    /// The harness refused the account's key, so its stored chats are locked.
    case locked
    /// The account's settings could not load.
    case failed
    /// The account's settings, or its key, are still loading.
    case loading
}

/// The open chat of an account: which chat is shown, its runs, the stores
/// its chats live in, and the actions on it.
@MainActor
final class ChatSession: ObservableObject, RunControllerDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")
    /// The id of the block holding a reply's rewritten text when it had none.
    private static let editedContentId = "edited-content"

    let account: HarnessAccount
    let controller: RunController
    let list: ChatList
    let attachments = OpenAttachments()
    let device: LocalThreadStore
    private var temporaryStore: LocalThreadStore
    @Published private(set) var open: OpenChat
    /// Chats moving between the cloud and this device, and their moves.
    private var moving: [String: Task<Void, Error>] = [:]
    /// The chat opened last, so updates of the open chat do not reopen it.
    private(set) var opened: String?
    private var refreshedRevision: (id: String, revision: String)?
    private var cancellables: Set<AnyCancellable> = []
    /// The change whose answer each chat is shown from.
    private var latestShown: [String: Int] = [:]
    private var updates = 0

    private lazy var cloudStore = CloudThreads(account: account, list: list.cloud, attachments: attachments)
    private lazy var deviceStore = DeviceThreads(account: account, store: device, controller: controller, attachments: attachments, list: list.deviceEdits) { [weak self] in self?.markSaved($0) }

    init(account: HarnessAccount, device: LocalThreadStore, cache: ChatListCache, receipts: RunReceiptStore?) {
        self.account = account
        self.device = device
        controller = RunController(account: account, receipts: receipts)
        list = ChatList(account: account, device: device, cache: cache)
        temporaryStore = DeviceThreadStore(directory: nil)
        open = OpenChat(local: !account.cloud)
        controller.delegate = self
        for child in [controller.objectWillChange.eraseToAnyPublisher(), list.objectWillChange.eraseToAnyPublisher(), account.objectWillChange.eraseToAnyPublisher()] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    var state: ChatState { controller.view }
    var running: Bool { [.submitting, .streaming, .queued].contains(state.status) }

    /// The open chat, at rest, ends on a reply that did not finish or on a
    /// message no reply answers, as one left by a turn that failed.
    var hasUnfinishedReply: Bool {
        guard state.status == .idle, open.loadingId == nil, open.failure == nil, let last = state.messages.last else { return false }
        return last.role.value1 == .user || last.isError == true
    }

    /// Whether the open chat takes a turn now: not while one is being
    /// submitted, a device chat's turn is starting, the chat loads or moves.
    var acceptsTurn: Bool {
        guard state.status != .submitting, open.loadingId == nil else { return false }
        if openStore().local, controller.startingThread != nil { return false }
        if let id = open.id, moving[id] != nil { return false }
        return true
    }

    /// The open chat is a new chat whose first turn gave it its id, and is
    /// not stored yet: the conversation on screen is the one that was blank.
    var isNewChatsFirstTurn: Bool { open.id != nil && open.unsaved == open.id }

    /// Why the open chat cannot take a turn, if it cannot. A chat on this
    /// device sends the settings this device holds, or kept of the
    /// account's, and reads no key; a stored chat waits for the account's
    /// settings and its key.
    var sendBlock: SendBlock? {
        sendBlock(onDevice: open.onDevice)
    }

    /// Why a chat on this device, or a stored one, could not take a turn.
    func sendBlock(onDevice: Bool) -> SendBlock? {
        if onDevice {
            if account.cloud || account.profileReady { return nil }
        } else {
            if account.keyLocked { return .locked }
            if account.profileReady && account.keyReady { return nil }
        }
        return account.profileFailed ? .failed : .loading
    }

    private func patch(_ change: (inout OpenChat) -> Void) {
        var next = open
        change(&next)
        open = next
    }

    func report(_ cause: Error) {
        guard !(cause is CancellationError), !account.disposed else { return }
        if let error = cause as? HarnessError {
            account.reportRateLimit(error.detail.rateLimit)
            // The chat changed from the copy shown, as when a reply ended
            // before the stop sent for it: it shows as the harness has it,
            // which a running reply's stream brings, rather than as failed.
            if error.action == .reload, let threadId = open.id {
                if !running { Task { await showStored(threadId) } }
                return
            }
            patch { $0.failure = error.detail }
            HarnessAccount.noteAuthenticationRequired(error)
        } else {
            patch { $0.failure = HarnessErrorBody(code: HarnessErrorCode.connection, message: cause.localizedDescription, action: .retry) }
        }
    }

    func dismissError() {
        patch { $0.failure = nil }
        controller.updateView { $0.error = nil }
    }

    private func markSaved(_ threadId: String) {
        if open.unsaved == threadId { patch { $0.unsaved = nil } }
    }

    /// The open chat's store. A temporary chat runs as a chat on this device
    /// whose thread lives only in memory, with or without cloud sync.
    func openStore() -> ThreadStore {
        if !open.temporary { return open.local ? deviceStore as ThreadStore : cloudStore }
        return DeviceThreads(account: account, store: temporaryStore, controller: controller, attachments: attachments, list: NoListEdits()) { [weak self] in self?.markSaved($0) }
    }

    /// The store of a chat: the open chat's own, or the one that lists it.
    func storeOf(_ threadId: String) -> ThreadStore {
        if open.id == threadId { return openStore() }
        return !account.cloud || list.isOnDevice(threadId) ? deviceStore as ThreadStore : cloudStore
    }

    func reset() {
        controller.reset()
        attachments.clear()
        patch {
            $0.id = nil
            $0.loadingId = nil
            $0.failedId = nil
            $0.failure = nil
            $0.notFound = false
            $0.unsaved = nil
            $0.model = ""
            $0.presetChosen = false
            $0.chosenPresetId = nil
            $0.modelChosen = false
            $0.webSearch = nil
        }
    }

    // MARK: - Opening

    /// The prompt of the open chat: the one chosen for it, or the profile's
    /// default for a new one.
    var presetId: String? {
        if open.presetChosen { return open.chosenPresetId }
        let preset = account.profile["defaultPromptPresetId"] as? String
        return preset.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What a new chat's saved prompt chooses and the user did not change. A
    /// model the catalog no longer offers is not shown.
    func presetChoice() -> PresetChoice {
        guard open.id == nil, let presetId,
              let presets = account.profile["customPromptPresets"] as? [[String: Any]],
              let preset = presets.first(where: { $0["id"] as? String == presetId }) else { return PresetChoice() }
        var choice = PresetChoice()
        if !open.modelChosen, let model = preset["model"] as? String, account.session?.models.contains(where: { $0.id == model && !$0.deprecated }) == true {
            choice.model = model
        }
        if open.webSearch == nil, let webSearch = preset["webSearchEnabled"] as? Bool { choice.webSearchEnabled = webSearch }
        return choice
    }

    /// The model a new chat follows: the one the user picked last, or the
    /// session's default.
    var pickedModel: String {
        let picked = account.profile["selectedModel"] as? String ?? ""
        return picked.isEmpty ? (account.session?.defaultModel ?? "") : picked
    }

    func newChat(local: Bool? = nil) {
        opened = nil
        reset()
        patch {
            $0.local = !account.cloud || (local ?? false)
            $0.temporary = false
        }
        temporaryStore = DeviceThreadStore(directory: nil)
        controller.clearReceipt()
    }

    @discardableResult
    func openChat(_ threadId: String, local: Bool? = nil) async throws -> OpenChatResult {
        let local = local ?? (!account.cloud || list.isOnDevice(threadId))
        reset()
        opened = threadId
        let shown = controller.track()
        patch { $0.loadingId = threadId; $0.temporary = false; $0.local = local }
        defer { if shown() { patch { $0.loadingId = nil } } }
        do {
            let store: ThreadStore = local ? deviceStore : cloudStore
            let result = try await store.get(threadId)
            guard shown() else { return .superseded }
            guard let result else {
                patch { $0.temporary = false; $0.local = local; $0.notFound = true; $0.failedId = threadId }
                return .notFound
            }
            controller.setView(ChatState(thread: result.window))
            patch {
                $0.id = result.window.id
                $0.temporary = false
                $0.local = local
                $0.model = result.window.model
                $0.presetChosen = true
                $0.chosenPresetId = result.window.presetId
                $0.webSearch = nil
            }
            // A run of the chat may still be live: one this app started, one
            // a relaunched app left behind, or one the harness names.
            guard let live = store.liveRun(result.window) else { return .opened }
            await account.client.locate(threadId: threadId, instance: live.instance)
            let (body, run) = try await store.follow(threadId, runId: live.runId)
            guard shown() else { return .superseded }
            Task { await controller.run(.follow, body, options: RunOptions(device: run, quiet: run != nil)) }
            return .opened
        } catch {
            guard shown() else { return .superseded }
            patch { $0.failedId = threadId }
            if (error as? HarnessError)?.code == HarnessErrorCode.threadNotFound {
                patch { $0.notFound = true }
                return .notFound
            }
            throw error
        }
    }

    /// Shows the open chat as it is stored once its run is over, as when the
    /// harness no longer has the run or had applied a turn sent again. A
    /// chat never saved keeps what it shows.
    private func showStored(_ threadId: String) async {
        guard open.id == threadId else { return }
        let shown = controller.track()
        do {
            let result = try await openStore().get(threadId)
            guard shown() else { return }
            if result != nil { markSaved(threadId) }
            if let result {
                controller.setView(ChatState(thread: result.window))
            } else {
                controller.updateView { $0.status = .idle; $0.error = nil }
            }
        } catch {
            report(error)
        }
    }

    /// Another device changed the open stored chat: it is read again, with
    /// the earlier pages the view had loaded. Returns whether the chat was
    /// deleted there, which leaves the list and the view.
    @discardableResult
    func refreshIfChanged() async -> Bool {
        guard let revision = account.chatRevision, account.keyReady, !open.onDevice, let id = open.id,
              open.loadingId == nil, open.unsaved != id, state.status == .idle else { return false }
        if let refreshed = refreshedRevision, refreshed.id == id, refreshed.revision == revision { return false }
        let shown = controller.track()
        do {
            guard var result = try await cloudStore.get(id) else { return false }
            let wanted = state.messages.count
            while result.window.hasOlder, result.window.messages.count < wanted {
                let older = try await cloudStore.older(id, before: result.window.messages.first?.id)
                if older.messages.isEmpty { break }
                result.window.messages.insert(contentsOf: older.messages, at: 0)
                result.window.hasOlder = older.hasOlder
            }
            guard shown(), state.status == .idle else { return false }
            controller.setView(ChatState(thread: result.window))
            refreshedRevision = (id, revision)
            patch {
                $0.model = result.window.model
                $0.chosenPresetId = result.window.presetId
                $0.presetChosen = true
                $0.webSearch = nil
            }
        } catch {
            guard shown() else { return false }
            if (error as? HarnessError)?.code == HarnessErrorCode.threadNotFound {
                list.cloud.remove(id)
                reset()
                patch { $0.notFound = true }
                return true
            }
            report(error)
        }
        return false
    }

    // MARK: - RunControllerDelegate

    func runStarted(threadId: String, runId: String) {}

    func runAccepted(threadId: String) {
        markSaved(threadId)
    }

    /// The chat list shows a stored chat as its run reports it.
    func runReported(_ summary: ThreadSummary) {
        if !open.onDevice, open.id == summary.id { list.cloud.reported(summary) }
    }

    func runSaved(_ run: DeviceRun, event: RunEvent, attached: Bool) async -> Bool {
        do {
            guard let saved = try await DeviceRunStorage.store(run, event: event, changedSince: controller.settingsChangedSince(run)) else { return true }
            markSaved(saved.id)
            guard open.id == saved.id else { return true }
            attachments.rememberThread(saved)
            controller.updateView { state in
                guard var shown = state.snapshot.thread, shown.id == saved.id, shown.title != saved.title else { return }
                shown.title = saved.title
                shown.titleState = saved.titleState
                state.snapshot.thread = shown
            }
            return true
        } catch {
            Self.logger.error("Failed to save a local chat: \(error, privacy: .public)")
            if attached {
                patch { $0.failure = HarnessErrorBody(code: HarnessErrorCode.localSaveFailed, message: "This chat could not be saved on this device.", action: .stop) }
            }
            return false
        }
    }

    func runEnded() {
        list.reload()
    }

    func runGone(threadId: String) async {
        await showStored(threadId)
    }

    // MARK: - Turns

    /// The fields every turn of the open chat has.
    private func turnDefaults(_ threadId: String) -> Turn {
        let offered = account.session?.widgets ?? []
        return Turn(
            clientRequestId: UUID().uuidString.lowercased(),
            threadId: threadId,
            widgets: GenUIRegistry.widgetNames.filter { offered.contains($0) },
            options: TurnOptions(model: open.model, timezone: TimeZone.current.identifier)
        )
    }

    private func turnSettings() -> TurnSettings {
        TurnSettings(first: open.id == nil || open.unsaved == open.id, presetId: presetId, presetChosen: open.presetChosen, projectId: open.projectId, profile: account.profile)
    }

    /// A new chat takes its id with its first turn, and keeps showing the
    /// prompt it started with and the settings the prompt chose.
    private func startChat(_ choice: PresetChoice) -> String {
        if let id = open.id { return id }
        let threadId = Chat.generateReverseId()
        opened = threadId
        patch {
            if !$0.presetChosen {
                $0.presetChosen = true
                $0.chosenPresetId = presetId
            }
            if let model = choice.model { $0.model = model }
            if let webSearch = choice.webSearchEnabled { $0.webSearch = webSearch }
            $0.id = threadId
            $0.unsaved = threadId
        }
        return threadId
    }

    /// A new chat's first turn leaves the settings its prompt chooses to the
    /// harness, which applies the prompt. Web search turned off in Settings
    /// stays off whatever the prompt chooses.
    private func leaveToPreset(_ options: TurnOptions?, _ choice: PresetChoice) -> TurnOptions? {
        guard var left = options else { return nil }
        if choice.model != nil { left.model = nil }
        if choice.webSearchEnabled != nil, left.webSearch != false { left.webSearch = nil }
        return left
    }

    /// The message a turn adds, under the id the harness stores it with. A
    /// message queued behind a running reply shows in the queue instead.
    private func sentMessage(_ turn: Turn) -> Components.Schemas.MessageRecord? {
        guard turn.kind == .send, state.status != .streaming, state.status != .queued else { return nil }
        let sent = (turn.attachments ?? []).compactMap(\.uploaded)
        return Components.Schemas.MessageRecord(id: turn.clientRequestId, role: .named(.user), createdAt: StoredThread.timestamp(Date()), content: turn.content ?? "", quote: turn.quote, attachments: sent.isEmpty ? nil : sent)
    }

    /// A message as the view shows it, without its uploads' contents.
    private func shownMessage(_ record: Components.Schemas.MessageRecord) -> HarnessMessage {
        HarnessMessage(
            id: record.id, role: record.role, createdAt: record.createdAt, content: record.content, timeline: record.timeline,
            quote: record.quote, model: record.model, modelDisplayName: record.modelDisplayName, isError: record.isError,
            isInterrupted: record.isInterrupted, usage: record.usage, annotations: record.annotations,
            attachments: record.attachments?.map {
                Components.Schemas.AttachmentView(id: $0.id, kind: $0.kind, fileName: $0.fileName, mimeType: $0.mimeType, size: $0.size, thumbnail: $0.thumbnail, textContent: $0.textContent, description: $0.description)
            }
        )
    }

    /// The messages a turn that regenerates, edits or continues leaves, as
    /// the harness applies it. A turn queued behind a running reply changes
    /// nothing yet.
    private func appliedTurn(_ turn: Turn) -> [HarnessMessage]? {
        let messages = state.messages
        guard state.status != .streaming, state.status != .queued,
              let index = messages.firstIndex(where: { $0.id == turn.messageId }) else { return nil }
        let target = messages[index]
        switch turn.kind {
        case .regenerate, .continue:
            guard target.role.value1 == .assistant else { return nil }
            return Array(messages[..<(turn.kind == .continue ? index + 1 : index)])
        case .edit:
            guard target.role.value1 == .user else { return nil }
            let sent = turn.attachments.map { $0.compactMap(\.uploaded) }
            var record = Components.Schemas.MessageRecord(id: turn.clientRequestId, role: .named(.user), createdAt: StoredThread.timestamp(Date()), content: turn.content ?? target.content ?? "", quote: turn.quote ?? target.quote)
            var edited = shownMessage(record)
            if let sent { record.attachments = sent.isEmpty ? nil : sent; edited = shownMessage(record) } else { edited.attachments = target.attachments }
            return Array(messages[..<index]) + [edited]
        default:
            return nil
        }
    }

    /// Sends a turn of the open chat. Returns whether its run finished
    /// while the view still showed the chat.
    @discardableResult
    func send(_ fields: TurnFields) async -> Bool {
        let threads = openStore()
        guard acceptsTurn else { return false }
        patch { $0.failure = nil }
        attachments.rememberSent(fields.attachments)
        // A turn the key could not be read for is not shown as sent.
        do { _ = try threads.runKey() } catch { report(error); return false }
        if open.id == nil, open.model.isEmpty { patch { $0.model = pickedModel } }
        let settings = turnSettings()
        let choice = presetChoice()
        let threadId = startChat(choice)
        var defaults = turnDefaults(threadId)
        defaults.options = leaveToPreset(defaults.options, choice)
        var fields = fields
        fields.options = fields.options.flatMap { leaveToPreset($0, choice) }
        let shown = controller.track()
        let before = state.messages
        let sent = sentMessage(fields.applied(to: defaults))
        if let sent { controller.updateView { $0.messages.append(shownMessage(sent)) } }
        let applied = appliedTurn(fields.applied(to: defaults))
        if let applied { controller.updateView { $0.messages = applied } }
        // A turn that did not start leaves the chat as the harness stores it.
        let unapply = { [weak self] in
            guard let self, let applied, shown(), state.messages == applied else { return }
            controller.updateView { $0.messages = before }
        }
        let status = state.status
        let submission = status == .streaming || status == .queued ? nil : Submission(threadId: threadId)
        func submit() async -> Bool {
            controller.retryPreparation = nil
            if let submission {
                controller.submission = submission
                controller.updateView { $0.status = .submitting; $0.runId = nil; $0.error = nil }
            }
            defer {
                if let submission, controller.submission === submission {
                    controller.submission = nil
                    controller.updateView { if $0.status == .submitting { $0.status = .idle } }
                }
            }
            do {
                // Each attempt reads the key it is sent with, so a retry after
                // the key changed carries the current one.
                let key = try threads.runKey()
                guard let turn = try await threads.prepareTurn(threadId, defaults: defaults, fields: fields, key: key, settings: settings), shown() else {
                    unapply()
                    return false
                }
                let pending = PendingTurn(input: turn.resend, run: turn.run)
                controller.pending = pending
                if let sent, let keep = turn.keep { await keep(sent) }
                if !shown() || submission?.cancelled == true {
                    if let run = turn.run { controller.settle(run) }
                    if shown() { controller.pending = nil }
                    unapply()
                    return false
                }
                let ran = await controller.run(.turn, .turn(turn.input), options: RunOptions(submission: submission, device: turn.run))
                if controller.pending?.input == pending.input { unapply() }
                return ran
            } catch {
                if shown() {
                    if submission != nil { controller.retryPreparation = submit }
                    report(error)
                }
                unapply()
                return false
            }
        }
        return await submit()
    }

    func cancel() async throws {
        try await controller.cancel(RunRequest(key: try openStore().runKey(), threadId: open.id ?? "", runId: state.snapshot.thread?.activeRun?.runId ?? state.runId))
    }

    /// The harness regenerates the reply it is named. A message is named by
    /// its index: a reply, or the user message it answers. A user message
    /// left without a reply is sent again with its own text. A run in
    /// progress is stopped first.
    @discardableResult
    func regenerate(at index: Int, options: TurnOptions? = nil) async -> Bool {
        let messages = state.messages
        guard messages.indices.contains(index) else { return false }
        let target = messages[index]
        let reply = target.role.value1 == .assistant ? target : (messages.indices.contains(index + 1) && messages[index + 1].role.value1 == .assistant ? messages[index + 1] : nil)
        var fields = TurnFields(options: options)
        if let reply {
            fields.kind = .regenerate
            fields.messageId = reply.id
            fields.content = ""
        } else {
            fields.kind = .edit
            fields.messageId = target.id
            fields.content = target.content ?? ""
        }
        if running { try? await cancel() }
        return await send(fields)
    }

    /// Asks the model to resume a reply where it stopped. The harness drops
    /// the messages after it, so the continued reply ends the chat.
    @discardableResult
    func continueReply(at index: Int, options: TurnOptions? = nil) async -> Bool {
        guard state.messages.indices.contains(index), state.messages[index].role.value1 == .assistant else { return false }
        return await send(TurnFields(kind: .continue, content: "", messageId: state.messages[index].id, options: options))
    }

    /// Reconnects to the open chat's run, or sends again the turn whose
    /// acceptance never arrived.
    @discardableResult
    func reconnect() async -> Bool {
        patch { $0.failure = nil }
        if let prepare = controller.retryPreparation { return await prepare() }
        let threads = openStore()
        if let pending = controller.pending {
            var input = pending.input
            do { input.key = try threads.runKey() } catch { report(error); return false }
            if let run = pending.run { controller.begin(run) }
            return await controller.run(.turn, .turn(input), options: RunOptions(device: pending.run))
        }
        if let threadId = open.id, let runId = state.runId ?? state.snapshot.thread?.activeRun?.runId {
            do {
                let (body, run) = try await threads.follow(threadId, runId: runId)
                return await controller.run(.follow, body, options: RunOptions(device: run))
            } catch {
                report(error)
                return false
            }
        }
        if let threadId = open.id {
            do { _ = try await openChat(threadId, local: open.local) } catch { report(error) }
        }
        return false
    }

    /// Retries what failed: a run that ended with an error runs again, as
    /// the harness decides from the chat; a refused request or a dropped
    /// stream reconnects.
    @discardableResult
    func retry(options: TurnOptions? = nil) async -> Bool {
        guard (state.failedRun != nil && state.status == .error) || hasUnfinishedReply else { return await reconnect() }
        return await send(TurnFields(kind: .retry, options: options))
    }

    /// Asks the harness for new arguments for a widget call, while the chat
    /// shows no run or error of its own. Returns why the retry did not repair
    /// the widget, if it did not.
    func retryToolCall(_ toolCallId: String) async -> HarnessErrorBody? {
        let threads = openStore()
        guard let threadId = open.id, open.loadingId == nil, moving[threadId] == nil, !running, state.status != .submitting,
              !(threads.local && controller.startingThread != nil) else {
            return HarnessErrorBody(code: HarnessErrorCode.threadNotFound, message: "This widget cannot be regenerated now.", action: .stop)
        }
        let shown = controller.track()
        let widgetRetry = WidgetRetry()
        do {
            let key = try threads.runKey()
            guard let turn = try await threads.prepareTurn(threadId, defaults: turnDefaults(threadId), fields: TurnFields(kind: .retryToolCall, content: "", toolCallId: toolCallId), key: key, settings: turnSettings()), shown() else {
                return HarnessErrorBody(code: HarnessErrorCode.threadNotFound, message: "This widget cannot be regenerated now.", action: .stop)
            }
            let repaired = await controller.run(.turn, .turn(turn.input), options: RunOptions(device: turn.run, widgetRetry: widgetRetry))
            return repaired ? nil : (widgetRetry.failure ?? RunController.connectionLost)
        } catch {
            return (error as? HarnessError)?.detail ?? RunController.connectionLost
        }
    }

    func sendQueued(_ queueId: String) async throws {
        try await controller.sendQueued(RunRequest(key: try openStore().runKey(), threadId: open.id ?? "", queueId: queueId))
    }

    func removeQueued(_ queueId: String) async throws {
        try await controller.removeQueued(RunRequest(key: try openStore().runKey(), threadId: open.id ?? "", queueId: queueId))
    }

    // MARK: - Settings of the open chat

    func setModel(_ model: String) {
        patch { $0.model = model; $0.modelChosen = true }
    }

    func setWebSearch(_ enabled: Bool) {
        patch { $0.webSearch = enabled }
    }

    func setTemporary(_ temporary: Bool) {
        patch { $0.temporary = temporary }
    }

    func setProject(_ projectId: String?) {
        patch { $0.projectId = projectId }
    }

    /// Chooses the open chat's prompt. A new chat shows what the prompt
    /// chooses until its first turn; the harness applies the prompt's
    /// settings to a chat it is named for, and the chat then shows them.
    func selectPreset(_ next: String?) async throws {
        guard let threadId = open.id else {
            patch { $0.presetChosen = true; $0.chosenPresetId = next; $0.modelChosen = false; $0.webSearch = nil }
            return
        }
        let before = (chosen: open.presetChosen, presetId: open.chosenPresetId)
        patch { $0.presetChosen = true; $0.chosenPresetId = next }
        let summary: ThreadSummary?
        do {
            summary = try await update(threadId, ThreadPatch(presetId: Nullable(next)))
        } catch {
            // A refused choice shows the prompt the chat kept.
            if open.id == threadId, open.chosenPresetId == next {
                patch { $0.presetChosen = before.chosen; $0.chosenPresetId = before.presetId }
            }
            throw error
        }
        if let summary, open.id == threadId {
            patch { $0.model = summary.model; $0.webSearch = nil }
        }
    }

    // MARK: - Actions

    private func showSummary(_ summary: ThreadSummary) {
        controller.updateView { $0.snapshot.thread = summary }
    }

    private func requireIdle(_ threadId: String) throws {
        if moving[threadId] != nil || controller.deviceRuns[threadId] != nil || controller.startingThread == threadId || (open.id == threadId && running) {
            throw HarnessTransfers.inFlight
        }
    }

    /// A chat takes no changes until its move has ended, the open chat's
    /// reopening included.
    private func whileMoving<T>(_ threadId: String, _ move: @escaping () async throws -> T) async throws -> T {
        let task = Task { try await move() }
        let tracked = Task<Void, Error> { _ = try await task.value }
        moving[threadId] = tracked
        defer { if moving[threadId] == tracked { moving[threadId] = nil } }
        return try await task.value
    }

    /// A new title or favorite state shows at once, and goes back when the
    /// chat's store refuses it.
    @discardableResult
    func update(_ threadId: String, _ patch: ThreadPatch) async throws -> ThreadSummary? {
        guard moving[threadId] == nil else { return nil }
        let store = storeOf(threadId)
        let unlist = list.preview(threadId, patch)
        let shown = state.snapshot.thread
        var titled: ThreadSummary?
        if var current = shown, current.id == threadId, let title = patch.title, open.id == threadId {
            current.title = title
            current.titleState = .named(.manual)
            titled = current
            showSummary(current)
        }
        let undo = { [weak self] in
            unlist()
            if let self, let shown, let titled, state.snapshot.thread == titled { showSummary(shown) }
        }
        updates += 1
        let update = updates
        let summary: ThreadSummary?
        do {
            summary = try await store.update(threadId, patch)
        } catch {
            undo()
            throw error
        }
        guard let summary else {
            undo()
            return nil
        }
        // The latest change answered shows the chat; one asked earlier and
        // answered later does not show it as it was before.
        if open.id == threadId, update > latestShown[threadId, default: 0] {
            latestShown[threadId] = update
            showSummary(summary)
        }
        return summary
    }

    /// A deleted chat leaves the list and the view at once, and is listed
    /// again when its store refuses to delete it.
    func remove(_ threadId: String) async throws {
        _ = try? await moving[threadId]?.value
        if let runId = controller.deviceRuns[threadId]?.run?.runId {
            Task { try? await controller.cancel(RunRequest(threadId: threadId, runId: runId)) }
        }
        let store = storeOf(threadId)
        let undo = list.previewRemoval(threadId)
        if open.id == threadId { reset() }
        do {
            try await store.remove(threadId)
        } catch {
            undo()
            throw error
        }
    }

    /// Deletes every chat the user can see here: the harness's stored chats
    /// with cloud sync, and the chats kept on this device.
    func removeAll() async throws {
        for move in moving.values { _ = try? await move.value }
        var cloudDeleted = false
        if account.cloud {
            let _: Deleted = try await account.post(.deleteAll)
            cloudDeleted = true
        }
        try await device.deleteAll()
        reset()
        list.clearCloud(confirmedEmpty: cloudDeleted)
        list.reloadDevice()
    }

    /// Forks the open chat from a message into a new chat holding the
    /// messages through it, and opens the fork once `opening` has returned,
    /// unless the view moved to another chat meanwhile.
    func fork(at messageIndex: Int, opening: @MainActor (_ forkId: String) async -> Void = { _ in }) async throws -> String? {
        guard let threadId = open.id, !open.temporary, state.messages.indices.contains(messageIndex) else { return nil }
        let messageId = state.messages[messageIndex].id
        let store = storeOf(threadId)
        let shown = controller.track()
        guard let forkId = try await store.fork(threadId, messageId: messageId), shown() else { return nil }
        await opening(forkId)
        guard shown() else { return nil }
        _ = try await openChat(forkId, local: store.local)
        return forkId
    }

    /// Message actions change one message of the open chat. The change shows
    /// at once and goes back when the chat's store refuses it; the chat then
    /// shows as its store answers, after the earlier messages the view
    /// loaded.
    private func changeMessage(
        at index: Int,
        _ change: (ThreadStore, String, String) async throws -> ThreadResult?,
        _ changeLoaded: @escaping ([HarnessMessage], String) -> [HarnessMessage]
    ) async throws {
        let before = state.messages
        guard let threadId = open.id, before.indices.contains(index), moving[threadId] == nil else { return }
        let messageId = before[index].id
        let shown = controller.track()
        let changed = changeLoaded(before, messageId)
        controller.updateView { $0.messages = changed }
        let undo = { [weak self] in
            guard let self, shown(), state.messages == changed else { return }
            controller.updateView { $0.messages = before }
        }
        let result: ThreadResult?
        do {
            result = try await change(storeOf(threadId), threadId, messageId)
        } catch {
            undo()
            throw error
        }
        guard let result else {
            undo()
            return
        }
        guard shown() else { return }
        controller.updateView { state in
            var loaded = state
            loaded.messages = changeLoaded(state.messages, messageId)
            let shown = ChatReducer.afterLoaded(loaded, result.window.messages, hasOlder: result.window.hasOlder)
            state.messages = shown.messages
            state.hasOlder = shown.hasOlder
            state.snapshot.thread = ThreadSummary(of: result.window)
        }
    }

    /// Removes one message; its reply, or the message it answers, stays. A
    /// chat keeps its last message.
    func deleteMessage(at index: Int) async throws {
        guard state.messages.count > 1 else { return }
        try await changeMessage(at: index) { store, threadId, messageId in
            try await store.deleteMessage(threadId, messageId: messageId)
        } _: { messages, messageId in
            messages.filter { $0.id != messageId }
        }
    }

    /// Rewrites a reply's text in place; later messages stay.
    func editReply(at index: Int, content: String) async throws {
        guard state.messages.indices.contains(index), state.messages[index].role.value1 == .assistant else { return }
        try await changeMessage(at: index) { store, threadId, messageId in
            try await store.editReply(threadId, messageId: messageId, content: content)
        } _: { messages, messageId in
            messages.map { $0.id == messageId ? Self.rewrittenReply($0, content) : $0 }
        }
    }

    /// A reply with its text rewritten, as the harness rewrites it: its
    /// content blocks collapse into one holding the text, where the first
    /// was.
    private static func rewrittenReply(_ message: HarnessMessage, _ text: String) -> HarnessMessage {
        let timeline = message.timeline ?? []
        let first = timeline.firstIndex { $0._type.value1 == .content }
        let edited = TimelineBlock(id: first.map { timeline[$0].id } ?? editedContentId, _type: .named(.content), content: text)
        var blocks: [TimelineBlock] = []
        for (index, block) in timeline.enumerated() {
            if index == first, !text.isEmpty { blocks.append(edited) }
            if block._type.value1 != .content { blocks.append(block) }
        }
        if first == nil, !text.isEmpty { blocks.append(edited) }
        var rewritten = message
        rewritten.content = text
        rewritten.timeline = blocks.isEmpty ? nil : blocks
        return rewritten
    }

    func share(_ threadId: String) async throws -> String {
        try await storeOf(threadId).share(threadId)
    }

    /// Every message before those shown, which the store gives a page at a
    /// time.
    func older() async throws {
        guard let threadId = open.id else { return }
        let shown = controller.track()
        // Each page is read from the first message of the page after it,
        // which may be one this client leaves out.
        var before = state.messages.first?.id
        while state.hasOlder {
            let page = try await storeOf(threadId).older(threadId, before: before)
            guard shown() else { return }
            let earlier = page.messages.shown.filter { message in !state.messages.contains { $0.id == message.id } }
            controller.updateView { $0.messages = earlier + $0.messages; $0.hasOlder = page.hasOlder }
            guard let first = page.messages.first?.id, first != before else { return }
            before = first
        }
    }

    /// Moves a stored chat to this device under the same id. A chat the
    /// harness stored a moment ago is put back as it was on the device.
    func moveToDevice(_ threadId: String, original: DeviceChatCopy? = nil) async throws {
        try requireIdle(threadId)
        try await whileMoving(threadId) { [self] in
            let moved: StoredThread
            if let original {
                moved = try await HarnessTransfers.placeOnDevice(account, store: device, thread: original.thread, originals: original.originals)
            } else {
                moved = try await HarnessTransfers.moveToDevice(account, store: device, threadId: threadId)
            }
            list.cloud.remove(threadId)
            list.deviceEdits.add(moved.summary)
            if open.id == threadId { _ = try await openChat(threadId, local: true) }
        }
    }

    /// Moves a chat from this device to the cloud under the same id, and
    /// returns the device copy it replaced.
    @discardableResult
    func moveToCloud(_ threadId: String) async throws -> DeviceChatCopy {
        try requireIdle(threadId)
        return try await whileMoving(threadId) { [self] in
            let (summary, original) = try await HarnessTransfers.moveToCloud(account, store: device, threadId: threadId)
            list.deviceEdits.remove(threadId)
            list.cloud.add(summary)
            if open.id == threadId { _ = try await openChat(threadId, local: false) }
            return original
        }
    }

    /// Keeps the open temporary chat under the same id where new chats are
    /// stored: in the cloud with cloud sync, or else on this device, once no
    /// run of it is left, so the reply is stored with it.
    func saveTemporary() async throws {
        guard let threadId = open.id, open.temporary, moving[threadId] == nil else { return }
        await runsEnded(threadId)
        try Task.checkCancellation()
        guard open.id == threadId else { return }
        try requireIdle(threadId)
        let cloud = account.cloud && !open.local
        let temporary = temporaryStore
        try await whileMoving(threadId) { [self] in
            if cloud {
                let (summary, _) = try await HarnessTransfers.moveToCloud(account, store: temporary, threadId: threadId)
                list.cloud.add(summary)
            } else {
                let saved = try await HarnessTransfers.moveOnDevice(from: temporary, to: device, threadId: threadId)
                list.deviceEdits.add(saved.summary)
            }
            if open.id == threadId { _ = try await openChat(threadId, local: !cloud) }
        }
    }

    /// Waits until no run of the chat is left: no device run reads it, and
    /// the view, while it shows the chat, runs nothing.
    private func runsEnded(_ threadId: String) async {
        let changes = Publishers.CombineLatest3(controller.$view, controller.$deviceRuns, $open).values
        for await (view, runs, shown) in changes {
            let running = [.submitting, .streaming, .queued].contains(view.status)
            if runs[threadId] == nil, !(shown.id == threadId && running) { return }
        }
    }

    /// Converts a file into the attachment the turn that uses it sends. An
    /// image's attachment carries the copy the harness gives models; the
    /// file itself is kept apart, to show and download.
    func upload(_ data: Data, fileName: String, mimeType: String) async throws -> Components.Schemas.Attachment {
        let attachment = try await HarnessUploads.upload(account, data: data, fileName: fileName, mimeType: mimeType)
        if attachment.kind.value1 == .image {
            attachments.keepOriginal(attachment.id, AttachmentOriginal(base64: data.base64EncodedString(), mimeType: mimeType.isEmpty ? attachment.mimeType : mimeType))
        }
        return attachment
    }

    /// The audio of a message of the open chat, read aloud by the harness.
    func speak(_ messageId: String) async throws -> HarnessResponse {
        guard let threadId = open.id else {
            throw HarnessError(code: HarnessErrorCode.threadNotFound, message: "This chat is not saved yet.", action: .stop)
        }
        return try await openStore().speech(threadId, messageId: messageId)
    }

    /// A document's text: a stored chat's messages leave it out, and the
    /// harness reads it from the chat; a chat on this device keeps it.
    func documentText(_ attachment: Attachment) async throws -> String {
        if let text = attachment.textContent { return text }
        return try await openStore().documentText(open.id, attachmentId: attachment.id)
    }

    func image(_ attachment: Attachment) async throws -> (data: Data, mimeType: String) {
        try await openStore().image(open.id, attachmentId: attachment.id, mimeType: attachment.mimeType)
    }
}

private struct Deleted: Decodable {
    var deleted: Int
}

/// The list edits of a store whose chats are not listed, as a temporary
/// chat's.
@MainActor
private final class NoListEdits: ListEdits {
    func add(_ summary: ThreadSummary) {}
    func replace(_ summary: ThreadSummary) {}
    func remove(_ threadId: String) {}
}
