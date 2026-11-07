import Foundation
import OSLog

/// A hint that rejoins a device chat's run after a relaunch, kept on the
/// device.
struct RunReceipt: Codable, Equatable, Sendable {
    let threadId: String
    let runId: String
    let instance: String
}

/// A run of a chat this device stores. Its final event returns the whole
/// thread, without the image bytes this device holds for it.
final class DeviceRun: @unchecked Sendable {
    let threadId: String
    let store: LocalThreadStore
    var images: ImagesById
    /// The originals of the images the turn sent, stored with the thread.
    var originals: Originals
    /// The run, once it started.
    var run: RunReceipt?
    var saved = false
    /// The chat stored the thread the run's final event returned. A final
    /// event without the thread leaves the chat without anything the run
    /// streamed.
    var threadStored = false
    /// When the run's turn read the chat, on the controller's clock.
    let since: Int

    init(threadId: String, store: LocalThreadStore, images: ImagesById = [:], originals: Originals = [:], since: Int) {
        self.threadId = threadId
        self.store = store
        self.images = images
        self.originals = originals
        self.since = since
    }
}

/// Orders the runs of each device chat by when their turns read the chat,
/// so a run's final event does not store the chat over the thread a later
/// run stored, which holds the earlier run's turn, as when the earlier
/// run's event arrives last on a stream rejoined after the later run ended.
final class StoredRuns: @unchecked Sendable {
    private let lock = NSLock()
    /// When the turn of the latest run that stored each chat read it.
    private var latest: [String: Int] = [:]

    /// Whether the run's final event may store its chat, which makes it the
    /// latest run that stored the chat.
    func claim(_ run: DeviceRun) -> Bool {
        lock.withLock { () -> Bool in
            if let stored = latest[run.threadId], stored > run.since { return false }
            latest[run.threadId] = run.since
            return true
        }
    }

    /// Whether a later run stored the run's chat, whose thread then holds
    /// what the run streamed as the harness finished it.
    func superseded(_ run: DeviceRun) -> Bool {
        lock.withLock { latest[run.threadId].map { $0 > run.since } ?? false }
    }
}

/// A turn sent whose run has not started. Its chat is sent again, with its
/// nonce, to reconnect.
struct PendingTurn {
    let input: Turn
    let run: DeviceRun?
}

final class Submission {
    let threadId: String
    var cancelled = false

    init(threadId: String) {
        self.threadId = threadId
    }
}

struct RunOptions {
    var submission: Submission?
    /// A device chat's run keeps reading when the view moves to another
    /// chat, so its reply is still saved.
    var device: DeviceRun?
    /// Rejoining a run left behind: losing it shows no error.
    var quiet = false
    /// The attempts made in a row to rejoin the run since its stream last
    /// delivered a frame.
    var rejoins = 0
    /// The turn was sent again after its connection was lost.
    var resent = false
    /// The view the run was started for, which a rejoin keeps.
    var version: Int?
    /// What a rejoined run continues from while the view shows another
    /// chat: the run's own state, whose cursor it resumes after.
    var state: ChatState?
    /// The run started before this stream: one followed by its id is, unless
    /// a stream that only queued it is rejoined.
    var started: Bool?
    /// A widget's retry leaves the chat's status and error as they were, and
    /// keeps why it failed here instead.
    var widgetRetry: WidgetRetry?
}

final class WidgetRetry {
    var failure: HarnessErrorBody?
}

/// What the chat around a run does as the run goes.
@MainActor
protocol RunControllerDelegate: AnyObject {
    /// The run the view shows started, under the thread the harness names.
    func runStarted(threadId: String, runId: String)
    /// The harness accepted a stored chat's turn, which stored a new chat.
    func runAccepted(threadId: String)
    /// The run the view shows changed the chat's summary, as when it
    /// started, titled the chat or ended.
    func runReported(_ summary: ThreadSummary)
    /// A device run's final event returns the thread to store. Returns
    /// whether it was stored.
    func runSaved(_ run: DeviceRun, event: RunEvent, attached: Bool) async -> Bool
    /// A run ended, which may have changed the chat list.
    func runEnded()
    /// The open chat's run is over though its stream did not say so, or the
    /// harness had applied the turn sent again, whose run another instance
    /// of it may still be running. A device run's chat holds nothing it
    /// streamed unless its final event was stored.
    func runGone(threadId: String, applied: Bool, device: DeviceRun?) async
    /// A device run the view moved away from is gone before its final event
    /// returned the thread: its chat stores what the run streamed.
    func runCutOff(_ run: DeviceRun, state: ChatState) async
}

/// Streams the runs of the chat a view shows: a turn's run, or a live run
/// it follows again, which replays from its first frame while the view
/// skips the frames it applied. A run whose stream drops is rejoined,
/// backing off while the harness cannot be reached.
@MainActor
final class RunController: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    /// A stream that broke without a reason from the harness, as when the
    /// connection dropped. Its run may go on.
    static let connectionLost = HarnessErrorBody(
        code: HarnessErrorCode.streamInterrupted,
        message: "The connection closed. Reconnect to continue.",
        action: .retry
    )

    @Published private(set) var view = ChatState()
    /// The device chats whose runs this app reads, by chat.
    @Published private(set) var deviceRuns: [String: DeviceRun] = [:]
    /// The messages whose reply the user stopped in this session, which keep
    /// saying so as the chat is read again.
    @Published private(set) var canceled: Set<String> = []
    /// The replies in this session the model ran out of room for, which keep
    /// saying so as the chat is read again.
    @Published private(set) var truncated: Set<String> = []
    /// When the open chat's error happened, so a wait the harness asks for
    /// counts from then.
    private(set) var errorAt: Date?
    var pending: PendingTurn?
    var submission: Submission?
    /// A turn sent while the open chat's reply stops waits for it to stop.
    var holding = false
    var retryPreparation: (() async -> Bool)?
    weak var delegate: RunControllerDelegate?
    let storedRuns = StoredRuns()

    private let account: HarnessAccount
    private let receipts: RunReceiptStore?
    /// When the turn of each device run this app started read its chat, by
    /// run.
    private var runsSince: [String: Int] = [:]
    /// Changes each time the view moves to another chat. A run started for
    /// the previous one no longer updates the view.
    private var generation = 0
    private var followers: [UUID: Task<Outcome, Never>] = [:]
    /// The device turn sent and not started yet. Its chat takes no other
    /// device turn until the turn starts or its stream ends.
    private var starting: DeviceRun?
    /// When each setting of a device chat last changed through the harness,
    /// on a clock that also dates the turns read from the chat.
    private var clock = 0
    private var settingChanges: [String: [String: Int]] = [:]
    /// Waits the seconds named before an attempt to rejoin a run.
    private let wait: @MainActor (TimeInterval) async throws -> Void

    init(
        account: HarnessAccount,
        receipts: RunReceiptStore?,
        wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.account = account
        self.receipts = receipts
        self.wait = wait
    }

    /// The view moves to another chat: runs it followed stop, other than
    /// device runs, which go on to save their replies.
    func reset(_ next: ChatState = ChatState()) {
        generation += 1
        followers.values.forEach { $0.cancel() }
        followers = [:]
        starting = nil
        pending = nil
        submission = nil
        retryPreparation = nil
        view = next
    }

    func setView(_ next: ChatState) {
        view = next
    }

    func updateView(_ change: (inout ChatState) -> Void) {
        var next = view
        change(&next)
        view = next
    }

    var startingThread: String? { starting?.threadId }

    /// Whether the view still shows the chat it showed when this was called.
    func track() -> () -> Bool {
        let version = generation
        return { [weak self] in version == self?.generation }
    }

    /// A device turn about to be sent.
    func begin(_ run: DeviceRun) {
        starting = run
    }

    func tick() -> Int {
        clock += 1
        return clock
    }

    /// The user changed settings of a device chat through the harness.
    func settingsChanged(threadId: String, _ settings: [String]) {
        let at = tick()
        var changes = settingChanges[threadId] ?? [:]
        for setting in settings { changes[setting] = at }
        settingChanges[threadId] = changes
    }

    /// The settings of a device chat changed after a run's turn read it.
    func settingsChangedSince(_ run: DeviceRun) -> [String] {
        (settingChanges[run.threadId] ?? [:]).filter { $0.value > run.since }.map(\.key)
    }

    /// When a device run's turn read its chat: a run this app started says,
    /// and one an earlier launch left behind read it before anything this
    /// app changed.
    func since(ofRun runId: String) -> Int {
        runsSince[runId] ?? 0
    }

    func settle(_ run: DeviceRun) {
        if starting === run { starting = nil }
    }

    /// What a run's stream left of the run as it ended or broke.
    private struct Outcome {
        var runId: String?
        var threadId: String
        var started: Bool
        var succeeded = false
        var state: ChatState
        var failure: Error?
        /// The stream applied a frame the view did not hold yet.
        var progressed = false
    }

    /// Streams a run, applying its frames to the view. Returns whether the
    /// run finished, uncancelled, while the view still showed its chat.
    @discardableResult
    func run(_ route: HarnessRoute, _ body: RunBody, options: RunOptions = RunOptions()) async -> Bool {
        let device = options.device
        let widgetRetry = options.widgetRetry
        let follower = UUID()
        let version = options.version ?? generation
        let attached = { [weak self] in version == self?.generation }
        let initial = Outcome(runId: body.runId, threadId: body.threadId, started: options.started ?? (body.runId != nil), state: options.state ?? view)
        let task = Task { [weak self] () -> Outcome in
            var outcome = initial
            guard let self else { return outcome }
            do {
                let frames = try await account.events(route, body.sent(cursors: outcome.state.cursors, cacheSecret: PromptCacheSecret.secret(userId: account.userId)), threadId: outcome.threadId, lastEventId: body.lastEventId(cursors: outcome.state.cursors))
                for try await frame in frames {
                    let shown = attached()
                    if !shown, device == nil { break }
                    let event = frame.event
                    if let named = event.threadId { outcome.threadId = named }
                    outcome.runId = event.runId ?? outcome.runId
                    if case .runStarted = event { outcome.started = true }
                    let base = shown ? view : outcome.state
                    let next = try ChatReducer.reduce(base, frame, runHint: outcome.runId, widgetRetry: widgetRetry != nil)
                    let replayed = next == base && (!event.isTerminal || device == nil || device?.saved == true)
                    // A replayed frame leaves the view as it was.
                    if !replayed {
                        if next != base {
                            reportQuota(event)
                            if case .runError(let failed) = event {
                                if let widgetRetry { widgetRetry.failure = failed.error } else if shown { errorAt = Date() }
                            }
                        }
                        if event.isTerminal {
                            markCanceled(ChatReducer.canceled(by: event, in: base))
                            noteTruncation(ChatReducer.truncation(of: event))
                        }
                        outcome.progressed = true
                        outcome.state = next
                        if shown { view = next }
                        if case .runStarted(let event) = event {
                            self.started(RunReceipt(threadId: outcome.threadId, runId: event.runId, instance: event.instance), device: device, shown: shown && widgetRetry == nil)
                            if shown { delegate?.runStarted(threadId: event.threadId, runId: event.runId) }
                        }
                        if shown, let thread = next.snapshot.thread, thread != base.snapshot.thread {
                            delegate?.runReported(thread)
                        }
                    }
                    if let submission = options.submission, submission.cancelled, let runId = outcome.runId {
                        let _: RawJSON = try await account.post(.cancel, RunRequest(key: body.key, threadId: outcome.threadId, runId: runId), keyless: true, threadId: outcome.threadId)
                        submission.cancelled = false
                    }
                    if case .runFinished(let finished) = event { outcome.succeeded = finished.metadata.cancelled != true }
                    if replayed { continue }
                    if let device, case .stateDelta(let delta) = event, let queued = delta.runId,
                       delta.delta.contains(where: { patch in
                           if case .case1(let add) = patch { return add.value.queueId == queued }
                           return false
                       }) {
                        settle(device)
                    }
                    guard event.isTerminal else { continue }
                    if let device {
                        // A reply this device could not store keeps the run's
                        // receipt, so the run can be followed again.
                        guard await delegate?.runSaved(device, event: event, attached: attached()) != false else {
                            delegate?.runEnded()
                            continue
                        }
                        device.saved = true
                    }
                    forgetReceipt(outcome.runId)
                    delegate?.runEnded()
                    if case .runError(let failed) = event, failed.error.action == .reload, attached() {
                        pending = nil
                        await delegate?.runGone(threadId: outcome.threadId, applied: false, device: device)
                    }
                }
            } catch {
                outcome.failure = error
            }
            return outcome
        }
        if device == nil { followers[follower] = task }
        let outcome = await task.value
        followers[follower] = nil
        // A device run this app no longer reads is not shown as running, and
        // another turn may follow one that never started. One waiting to be
        // rejoined still runs, so it stays shown until the wait ends.
        defer {
            if let device {
                settle(device)
                if deviceRuns[device.threadId] === device { deviceRuns[device.threadId] = nil }
            }
        }
        guard let cause = outcome.failure else { return outcome.succeeded && attached() }
        if task.isCancelled || cause is CancellationError { return false }
        // A turn whose connection was lost before the harness answered goes
        // once more with its nonce, which the harness answers with the run
        // the first one started, or by saying it applied it.
        if case .turn = body, !options.resent, Self.lostBeforeAnswer(cause), device != nil || attached() {
            var again = options
            again.resent = true
            again.version = version
            again.state = attached() ? nil : outcome.state
            return await run(route, body, options: again)
        }
        // A stream cut off after its run started rejoins the run, which
        // replays it; a device run does so after the view moved on. Attempts
        // that deliver nothing wait longer each time, so a harness that
        // restarts is reached once its new instance answers.
        let delays = Constants.Harness.rejoinDelaysSeconds
        let rejoins = outcome.progressed ? 0 : options.rejoins
        if let runId = outcome.runId, rejoins < delays.count, Self.interrupted(cause), device != nil || attached() {
            if delays[rejoins] > 0 {
                do { try await wait(delays[rejoins]) } catch { return false }
            }
            guard device != nil || attached() else { return false }
            let follow: RunBody
            do {
                follow = RunBody(key: try body.keyed ? account.key() : nil, threadId: outcome.threadId, runId: runId)
            } catch {
                if attached() { fail(error) }
                return false
            }
            var again = options
            again.rejoins = rejoins + 1
            again.started = outcome.started
            again.version = version
            again.state = attached() ? nil : outcome.state
            return await run(.follow, follow, options: again)
        }
        if attached() {
            if Self.gone(cause) {
                pending = nil
                forgetReceipt(outcome.runId)
                await delegate?.runGone(threadId: body.threadId, applied: (cause as? HarnessError)?.code == HarnessErrorCode.alreadyApplied, device: device)
            } else if let widgetRetry {
                widgetRetry.failure = (cause as? HarnessError)?.detail ?? Self.connectionLost
                account.reportRateLimit(widgetRetry.failure?.rateLimit)
            } else if !options.quiet {
                // A run the harness refused to follow is gone. One that could
                // not be reached keeps its receipt, so it can still be
                // rejoined.
                fail(cause, started: outcome.started)
            } else if let refusal = cause as? HarnessError, refusal.status != nil {
                forgetReceipt(outcome.runId)
            }
        } else if let device, Self.gone(cause) {
            forgetReceipt(outcome.runId)
            await delegate?.runCutOff(device, state: outcome.state)
        }
        return false
    }

    /// A stream that broke, or a request that could not reach the harness:
    /// the run may go on.
    private static func interrupted(_ cause: Error) -> Bool {
        guard let error = cause as? HarnessError else { return true }
        return error.code == HarnessErrorCode.streamInterrupted || error.code == HarnessErrorCode.connection
    }

    /// A request whose connection was lost before any answer, as when the
    /// system sends it on a kept-open connection the harness closed while
    /// the app was in the background. Only sending a request fails this
    /// way, so nothing of its stream arrived.
    private static func lostBeforeAnswer(_ cause: Error) -> Bool {
        (cause as? HarnessError)?.urlErrorCode == .networkConnectionLost
    }

    /// The chat changed from the copy this client shows, as when the harness
    /// had applied a turn sent again, or no longer has the run.
    private static func gone(_ cause: Error) -> Bool {
        (cause as? HarnessError)?.action == .reload
    }

    private func started(_ receipt: RunReceipt, device: DeviceRun?, shown: Bool) {
        if let device {
            settle(device)
            device.run = receipt
            deviceRuns[device.threadId] = device
            runsSince[receipt.runId] = device.since
            // A chat on this device is rejoined after a relaunch through this
            // receipt, whichever chat the view shows.
            receipts?.write(receipt)
        }
        guard shown else { return }
        pending = nil
        // A stored chat names its run itself.
        if device == nil { delegate?.runAccepted(threadId: receipt.threadId) }
    }

    /// The open chat's run ended with its stream, refused or cut off. A turn
    /// refused before it started, as one queued behind a reply, leaves the
    /// reply streaming.
    func fail(_ cause: Error, started: Bool = true) {
        let detail = (cause as? HarnessError)?.detail ?? Self.connectionLost
        errorAt = Date()
        updateView { state in
            state.error = detail
            if started || !(state.status == .streaming || state.status == .queued) {
                state.status = .error
                state.stopping = false
            }
            if detail.code == HarnessErrorCode.chatFlagged { state.flagged = true }
        }
        account.reportRateLimit(detail.rateLimit)
    }

    /// The quota a run reports as it starts and as it ends. A run that ends
    /// reporting no quota this client shows spends the hourly budget the
    /// chat access reported.
    private func reportQuota(_ event: RunEvent) {
        switch event {
        case .stateSnapshot(let snapshot):
            account.reportRateLimit(snapshot.snapshot.rateLimit)
        case .runFinished(let finished):
            account.reportRateLimit(finished.metadata.rateLimit)
            if finished.metadata.rateLimit?.isShown != true { account.reportUsage(finished.metadata.usage) }
        case .runError(let failed):
            account.reportRateLimit(failed.metadata?.rateLimit)
            if failed.metadata?.rateLimit?.isShown != true { account.reportUsage(failed.metadata?.usage) }
        default:
            break
        }
    }

    func cancel(_ request: RunRequest) async throws {
        if view.status == .submitting, request.runId == nil, submission?.threadId == request.threadId {
            submission?.cancelled = true
            return
        }
        let _: RawJSON = try await account.post(.cancel, request, keyless: true, threadId: request.threadId)
    }

    func markCanceled(_ messageIds: [String]) {
        if !messageIds.isEmpty { canceled.formUnion(messageIds) }
    }

    /// Records whether the model ran out of room for each reply a run
    /// committed as it ended, so a reply continued since says so only if it
    /// ran out again.
    func noteTruncation(_ truncation: (replies: [String], truncated: Bool)) {
        guard !truncation.replies.isEmpty else { return }
        if truncation.truncated { truncated.formUnion(truncation.replies) } else { truncated.subtract(truncation.replies) }
    }

    /// Returns once the run the open chat stops has ended, or the view moved
    /// to another chat.
    func stopped() async {
        for await state in $view.values where !state.isStopping { return }
    }

    func sendQueued(_ request: RunRequest) async throws {
        let _: RawJSON = try await account.post(.queueSend, request, keyless: true, threadId: request.threadId)
    }

    func removeQueued(_ request: RunRequest) async throws {
        let _: RawJSON = try await account.post(.queueRemove, request, keyless: true, threadId: request.threadId)
    }

    func receipt(of threadId: String) -> RunReceipt? {
        receipts?.read(threadId: threadId)
    }

    /// A run that ended is not followed again after a relaunch.
    private func forgetReceipt(_ runId: String?) {
        if let runId { receipts?.forget(runId: runId) }
    }

    /// A deleted chat's run is not followed again.
    func forgetReceipt(of threadId: String) {
        receipts?.forget(threadId: threadId)
    }

    func clearReceipts() {
        receipts?.clear()
    }
}

/// What a run's stream is asked with: a turn, or a run to follow.
enum RunBody {
    case turn(Turn)
    case follow(key: String?, threadId: String, runId: String)

    init(key: String?, threadId: String, runId: String) {
        self = .follow(key: key, threadId: threadId, runId: runId)
    }

    var threadId: String {
        switch self {
        case .turn(let turn): return turn.threadId
        case .follow(_, let threadId, _): return threadId
        }
    }

    var runId: String? {
        if case .follow(_, _, let runId) = self { return runId }
        return nil
    }

    var key: String? {
        switch self {
        case .turn(let turn): return turn.key
        case .follow(let key, _, _): return key
        }
    }

    /// Whether the chat is stored, so a reconnect carries the content key.
    var keyed: Bool {
        switch self {
        case .turn(let turn): return turn.local != true
        case .follow(let key, _, _): return key != nil
        }
    }

    /// The body as sent. A turn is scoped to this device's prompt cache, so
    /// every turn of the account shares it. Following a run resumes after the
    /// last frame of it this client applied, when it applied one.
    func sent(cursors: [String: Int], cacheSecret: String?) -> some Encodable {
        switch self {
        case .turn(var turn):
            if let cacheSecret {
                var options = turn.options ?? TurnOptions()
                options.cacheSecret = cacheSecret
                turn.options = options
            }
            return AnyEncodable(turn)
        case .follow(let key, let threadId, let runId): return AnyEncodable(RunRequest(key: key, threadId: threadId, runId: runId))
        }
    }

    func lastEventId(cursors: [String: Int]) -> Int? {
        guard case .follow(_, _, let runId) = self else { return nil }
        return cursors[runId]
    }
}

/// Keeps the receipts of device runs across relaunches, one for the latest
/// run of each chat, for one account.
final class RunReceiptStore: Sendable {
    private let key: String
    private let defaults: UserDefaults

    init(userId: String?, defaults: UserDefaults = .standard) {
        key = Constants.Harness.runReceiptKeyPrefix + (userId ?? "anonymous")
        self.defaults = defaults
    }

    func read(threadId: String) -> RunReceipt? {
        all().last { $0.threadId == threadId }
    }

    /// Keeps a run's receipt in place of its chat's earlier one.
    func write(_ receipt: RunReceipt) {
        save(all().filter { $0.threadId != receipt.threadId } + [receipt])
    }

    func forget(runId: String) {
        let kept = all()
        if kept.contains(where: { $0.runId == runId }) { save(kept.filter { $0.runId != runId }) }
    }

    func forget(threadId: String) {
        let kept = all()
        if kept.contains(where: { $0.threadId == threadId }) { save(kept.filter { $0.threadId != threadId }) }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// The receipts kept, the latest last. A receipt kept on its own, as an
    /// earlier version of the app kept one, is the only one.
    private func all() -> [RunReceipt] {
        guard let data = defaults.data(forKey: key) else { return [] }
        if let receipts = try? JSONDecoder().decode([RunReceipt].self, from: data) { return receipts }
        return (try? JSONDecoder().decode(RunReceipt.self, from: data)).map { [$0] } ?? []
    }

    /// Keeps the latest receipts, as many as the limit allows.
    private func save(_ receipts: [RunReceipt]) {
        guard !receipts.isEmpty else {
            clear()
            return
        }
        defaults.set(try? JSONEncoder().encode(Array(receipts.suffix(Constants.Harness.runReceiptLimit))), forKey: key)
    }
}

extension RunEvent {
    var threadId: String? {
        switch self {
        case .runStarted(let event): return event.threadId
        case .stateDelta(let event): return event.threadId
        case .runFinished(let event): return event.threadId
        case .runError(let event): return event.threadId
        default: return nil
        }
    }
}
