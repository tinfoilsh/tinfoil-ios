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
    var rejoined = false
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
    /// The open chat's run is over though its stream did not say so.
    func runGone(threadId: String) async
}

/// Streams the runs of the chat a view shows: a turn's run, or a live run
/// it follows again, which replays from its first frame while the view
/// skips the frames it applied. A run whose stream drops is rejoined once.
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
    /// When the open chat's error happened, so a wait the harness asks for
    /// counts from then.
    private(set) var errorAt: Date?
    var pending: PendingTurn?
    var submission: Submission?
    var retryPreparation: (() async -> Bool)?
    weak var delegate: RunControllerDelegate?

    private let account: HarnessAccount
    private let receipts: RunReceiptStore?
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

    init(account: HarnessAccount, receipts: RunReceiptStore?) {
        self.account = account
        self.receipts = receipts
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
                        await delegate?.runGone(threadId: outcome.threadId)
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
        // another turn may follow one that never started.
        if let device {
            settle(device)
            if deviceRuns[device.threadId] === device { deviceRuns[device.threadId] = nil }
        }
        guard let cause = outcome.failure else { return outcome.succeeded && attached() }
        if task.isCancelled || cause is CancellationError { return false }
        // A stream cut off after its run started rejoins the run once, which
        // replays it; a device run does so after the view moved on.
        if let runId = outcome.runId, !options.rejoined, Self.interrupted(cause), device != nil || attached() {
            let follow: RunBody
            do {
                follow = RunBody(key: try body.keyed ? account.key() : nil, threadId: outcome.threadId, runId: runId)
            } catch {
                if attached() { fail(error) }
                return false
            }
            var again = options
            again.rejoined = true
            again.started = outcome.started
            again.version = version
            again.state = attached() ? nil : outcome.state
            return await run(.follow, follow, options: again)
        }
        if attached() {
            if Self.gone(cause) {
                pending = nil
                forgetReceipt(outcome.runId)
                await delegate?.runGone(threadId: body.threadId)
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
        }
        return false
    }

    /// A stream that broke, or a request that could not reach the harness:
    /// the run may go on.
    private static func interrupted(_ cause: Error) -> Bool {
        guard let error = cause as? HarnessError else { return true }
        return error.code == HarnessErrorCode.streamInterrupted || error.code == HarnessErrorCode.connection
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
        }
        guard shown else { return }
        pending = nil
        // A stored chat names its run itself; a chat on this device is
        // rejoined after a relaunch through this receipt.
        if device != nil { receipts?.write(receipt) } else { delegate?.runAccepted(threadId: receipt.threadId) }
    }

    /// The open chat's run ended with its stream, refused or cut off. A turn
    /// refused before it started, as one queued behind a reply, leaves the
    /// reply streaming.
    func fail(_ cause: Error, started: Bool = true) {
        let detail = (cause as? HarnessError)?.detail ?? Self.connectionLost
        errorAt = Date()
        updateView { state in
            state.error = detail
            if started || !(state.status == .streaming || state.status == .queued) { state.status = .error }
            if detail.code == HarnessErrorCode.chatFlagged { state.flagged = true }
        }
        account.reportRateLimit(detail.rateLimit)
    }

    /// The quota a run reports as it starts and as it ends.
    private func reportQuota(_ event: RunEvent) {
        switch event {
        case .stateSnapshot(let snapshot):
            account.reportRateLimit(snapshot.snapshot.rateLimit)
        case .runFinished(let finished):
            account.reportRateLimit(finished.metadata.rateLimit)
            if finished.metadata.rateLimit?.kind == nil { account.reportUsage(finished.metadata.usage) }
        case .runError(let failed):
            account.reportRateLimit(failed.metadata?.rateLimit)
            if failed.metadata?.rateLimit?.kind == nil { account.reportUsage(failed.metadata?.usage) }
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

    func sendQueued(_ request: RunRequest) async throws {
        let _: RawJSON = try await account.post(.queueSend, request, keyless: true, threadId: request.threadId)
    }

    func removeQueued(_ request: RunRequest) async throws {
        let _: RawJSON = try await account.post(.queueRemove, request, keyless: true, threadId: request.threadId)
    }

    func receipt() -> RunReceipt? {
        receipts?.read()
    }

    /// A run that ended is not followed again after a relaunch.
    private func forgetReceipt(_ runId: String?) {
        if let runId, receipts?.read()?.runId == runId { receipts?.clear() }
    }

    func clearReceipt() {
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

/// Keeps the receipt of a device run across relaunches, for one account.
final class RunReceiptStore: Sendable {
    private let key: String
    private let defaults: UserDefaults

    init(userId: String?, defaults: UserDefaults = .standard) {
        key = Constants.Harness.runReceiptKeyPrefix + (userId ?? "anonymous")
        self.defaults = defaults
    }

    func read() -> RunReceipt? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(RunReceipt.self, from: $0) }
    }

    func write(_ receipt: RunReceipt) {
        defaults.set(try? JSONEncoder().encode(receipt), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
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
