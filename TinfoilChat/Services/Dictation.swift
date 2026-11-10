import Foundation
import os

/// Dictation, sent to be transcribed in short recordings while the user keeps
/// talking. Each recording's text waits, in order, for the composer of the
/// chat it was dictated in, and the recording is kept on this device until
/// the composer takes it, so a failure, a relaunch or a crash loses no more
/// than the recording under way.
@MainActor
final class Dictation {
    typealias Transcribe = (_ recording: Data, _ fileName: String) async throws -> String

    struct State: Equatable {
        /// Recordings on their first attempt, which the composer waits for
        /// once recording stops.
        var transcribing = false
        /// Recordings whose first attempt failed, being tried again.
        var retrying = 0
        /// Recordings that could not be transcribed, kept until the user
        /// tries them again or discards them.
        var failed = 0
        /// The chats whose composer has dictated text to take.
        var readyChatIds: Set<String> = []
    }

    private final class Segment {
        let record: DictationStore.Segment
        /// Kept on this device until its text reaches the composer, unless
        /// it was dictated in a temporary chat.
        let persist: Bool
        var audio: Data?
        var text: String?
        /// The recording is still being read from its file.
        var reading = false
        /// Attempts that failed, and the next attempt's place in the retry
        /// schedule.
        var attempts = 0
        var retries = 0
        var retryAt: Date?
        var attempt: Task<Void, Never>?
        var failed = false
        /// The segment's writes to storage, in the order they were made.
        var saving: Task<Void, Never>?

        init(record: DictationStore.Segment, persist: Bool) {
            self.record = record
            self.persist = persist
        }

        var id: String { record.id }
        var inFlight: Bool { attempt != nil }
        var waiting: Bool { text == nil && !failed }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Dictation")

    /// Told each change of the state.
    var onChange: ((State) -> Void)?
    private(set) var state = State()

    private let retryDelays: [TimeInterval]
    private var segments: [String: Segment] = [:]
    private var store: DictationStore?
    private var transcribe: Transcribe?
    private var wake: Task<Void, Never>?
    /// Counts the accounts dictation was opened for, so work for an earlier
    /// one is dropped.
    private var generation = 0

    init(retryDelays: [TimeInterval] = Constants.Audio.Dictation.retryDelays) {
        self.retryDelays = retryDelays
    }

    /// The account dictation is kept for and transcribed with. What the
    /// account left on this device is transcribed again, without the
    /// composer waiting for it.
    func open(store: DictationStore?, transcribe: @escaping Transcribe) {
        reset()
        self.store = store
        self.transcribe = transcribe
        guard let store else { return }
        let generation = self.generation
        Task { [weak self] in
            let kept = await store.load()
            guard let self, self.generation == generation else { return }
            for (record, audio) in kept where self.segments[record.id] == nil {
                let segment = Segment(record: record, persist: true)
                segment.audio = audio
                segment.text = record.text
                if record.text == nil { segment.attempts = 1 }
                if audio == nil && record.text == nil {
                    self.forget(segment)
                } else {
                    self.segments[segment.id] = segment
                }
            }
            self.work()
        }
    }

    /// Forgets dictation in memory and stops transcribing it, as when the
    /// account signs out. What the account keeps on this device stays with
    /// it.
    func reset() {
        generation += 1
        wake?.cancel()
        wake = nil
        for segment in segments.values {
            segment.attempt?.cancel()
        }
        segments = [:]
        store = nil
        transcribe = nil
        refresh()
    }

    /// A recording of a chat's dictation ended: it is read, kept and
    /// transcribed. A dictation's recordings are numbered in the order they
    /// were made.
    func recorded(_ file: URL, chatId: String, dictationId: String, index: Int, startedAt: Date, persist: Bool) {
        let record = DictationStore.Segment(chatId: chatId, dictationId: dictationId, index: index, startedAt: startedAt)
        let segment = Segment(record: record, persist: persist)
        segment.reading = true
        segments[segment.id] = segment
        refresh()
        let generation = self.generation
        Task { [weak self] in
            let audio = try? await Task.detached { try Data(contentsOf: file) }.value
            // The recorder's file goes once it is read, as it is not
            // encrypted; the recording is kept encrypted, if at all.
            try? FileManager.default.removeItem(at: file)
            guard let self, self.generation == generation, self.segments[segment.id] === segment else { return }
            segment.reading = false
            guard let audio, !audio.isEmpty else {
                self.segments[segment.id] = nil
                self.refresh()
                return
            }
            segment.audio = audio
            self.save(segment) { store in try await store.save(record, audio: audio) }
            self.work()
        }
    }

    /// The dictated text of a chat, in order, up to the first recording
    /// still waiting for its own; the chat's composer takes it.
    func take(chatId: String) -> [String] {
        var texts: [String] = []
        for dictation in dictations(of: chatId) {
            for segment in dictation {
                guard let text = segment.text else { break }
                forget(segment)
                if !text.isEmpty { texts.append(text) }
            }
        }
        refresh()
        return texts
    }

    /// Forgets a dictation, as when its recording is canceled.
    func discard(dictationId: String) {
        for segment in segments.values where segment.record.dictationId == dictationId {
            forget(segment)
        }
        refresh()
    }

    /// Transcribes again the recordings that failed.
    func retry() {
        for segment in segments.values where segment.failed {
            segment.failed = false
            segment.retries = 0
            segment.retryAt = nil
        }
        work()
    }

    /// Forgets the recordings that failed, so the text after them arrives.
    func discardFailed() {
        for segment in segments.values where segment.failed {
            forget(segment)
        }
        refresh()
    }

    /// Starts the attempts that are due: one recording's first attempt and
    /// one retry at a time, oldest first, so a recording being retried never
    /// holds up one the composer waits for.
    private func work() {
        wake?.cancel()
        wake = nil
        let now = Date()
        let pending = segments.values
            .filter { $0.audio != nil && $0.waiting && !$0.reading && !$0.inFlight }
            .sorted(by: Dictation.order)
        let inFlight = segments.values.filter { $0.inFlight }
        for first in [true, false] {
            if inFlight.contains(where: { ($0.attempts == 0) == first }) { continue }
            if let next = pending.first(where: { ($0.attempts == 0) == first && ($0.retryAt ?? .distantPast) <= now }) {
                attempt(next)
            }
        }
        // An attempt that ends starts the next one due; a retry not yet due
        // wakes the queue when it is.
        if let due = pending.compactMap({ $0.retryAt }).filter({ $0 > now }).min() {
            wake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(due.timeIntervalSince(now)))
                guard !Task.isCancelled else { return }
                self?.work()
            }
        }
        refresh()
    }

    private func attempt(_ segment: Segment) {
        guard let transcribe, let audio = segment.audio else { return }
        let generation = self.generation
        let fileName = "\(segment.id).\(Constants.Audio.recordingFileExtension)"
        segment.attempt = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await Dictation.withDeadline {
                    try Task.checkCancellation()
                    return try await transcribe(audio, fileName)
                })
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation, self.segments[segment.id] === segment else { return }
            segment.attempt = nil
            switch result {
            case .success(let text):
                segment.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                segment.audio = nil
                var record = segment.record
                record.text = segment.text
                let transcribed = record
                self.save(segment) { store in try await store.save(transcribed: transcribed) }
            case .failure(let error):
                let delay = self.retryDelay(error, retries: segment.retries)
                segment.attempts += 1
                segment.retries += 1
                if let delay {
                    segment.retryAt = Date().addingTimeInterval(delay)
                } else {
                    Dictation.logger.warning("Dictation could not be transcribed")
                    segment.failed = true
                }
            }
            self.work()
        }
    }

    /// The transcription, abandoned when it is not answered in time or the
    /// recording is forgotten.
    private static func withDeadline(_ operation: @escaping () async throws -> String) async throws -> String {
        let work = Task { try await operation() }
        let deadline = Task {
            try await Task.sleep(for: .seconds(Constants.Audio.Dictation.attemptTimeoutSeconds))
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// How long to wait before transcribing a recording again after an
    /// attempt failed, or nil when it waits for the user instead.
    private func retryDelay(_ error: Error, retries: Int) -> TimeInterval? {
        guard retries < retryDelays.count else { return nil }
        let delay = retryDelays[retries]
        guard let refusal = error as? HarnessError else { return delay }
        guard refusal.action == .retry || refusal.action == .wait else { return nil }
        return max(delay, TimeInterval(refusal.detail.retryAfter ?? 0))
    }

    /// Each dictation's recordings in order, the earliest dictation first,
    /// of one chat or of every chat.
    private func dictations(of chatId: String? = nil) -> [[Segment]] {
        let shown = segments.values.filter { chatId == nil || $0.record.chatId == chatId }
        return Dictionary(grouping: shown, by: { $0.record.dictationId }).values
            .map { $0.sorted(by: Dictation.order) }
            .sorted { $0[0].record.startedAt < $1[0].record.startedAt }
    }

    private func forget(_ segment: Segment) {
        segment.attempt?.cancel()
        segments[segment.id] = nil
        let id = segment.id
        save(segment) { store in await store.remove(id) }
    }

    private func save(_ segment: Segment, _ write: @escaping (DictationStore) async throws -> Void) {
        guard segment.persist, let store else { return }
        let previous = segment.saving
        segment.saving = Task {
            await previous?.value
            do {
                try await write(store)
            } catch {
                Dictation.logger.warning("Failed to save dictation: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func refresh() {
        let waiting = segments.values.filter { $0.waiting }
        let next = State(
            transcribing: waiting.contains { $0.attempts == 0 },
            retrying: waiting.filter { $0.attempts > 0 }.count,
            failed: segments.values.filter { $0.failed }.count,
            readyChatIds: Set(dictations().filter { $0[0].text != nil }.map { $0[0].record.chatId })
        )
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private static func order(_ first: Segment, _ second: Segment) -> Bool {
        first.record.startedAt != second.record.startedAt
            ? first.record.startedAt < second.record.startedAt
            : first.record.index < second.record.index
    }
}
