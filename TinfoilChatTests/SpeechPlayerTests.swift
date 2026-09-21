import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct SpeechPlayerTests {
    private let owner = SpeechOwner(chatId: "chat", messageId: "message")

    @Test(.timeLimit(.minutes(1)))
    func aCurrentInterruptionStopsPlaybackAndSurfacesTheError() async throws {
        let output = SilentSpeechOutput()
        let player = SpeechPlayer(output: output)
        var scheduled = output.scheduled.makeAsyncIterator()
        try player.read(owner: owner, content: "Answer.", service: ShortSpeechService())
        _ = await scheduled.next()
        #expect(player.snapshot.status == .playing)
        var stopped = false
        output.onStop = { stopped = true }
        let interruption = try #require(output.interruptions.last)
        interruption(.interrupted)
        #expect(stopped)
        #expect(player.snapshot.owner == owner)
        #expect(player.snapshot.status == .failed(.interrupted))
        #expect(player.pendingFailure(for: owner) == .interrupted)
        let lateCompletion = try #require(output.completions.last)
        lateCompletion()
        #expect(player.snapshot.status == .failed(.interrupted))
    }

    @Test(.timeLimit(.minutes(1)))
    func playbackCompletionIsScopedToItsGeneration() async throws {
        let output = SilentSpeechOutput()
        let player = SpeechPlayer(output: output)
        var scheduled = output.scheduled.makeAsyncIterator()
        try player.read(owner: owner, content: "First response.", service: ShortSpeechService())
        _ = await scheduled.next()
        #expect(player.snapshot.status == .playing)
        let oldCompletion = try #require(output.completions.first)

        let next = SpeechOwner(chatId: "chat", messageId: "next")
        try player.read(owner: next, content: "Next response.", service: ShortSpeechService())
        _ = await scheduled.next()
        oldCompletion()
        #expect(player.snapshot.owner == next)
        #expect(player.snapshot.status == .playing)
        let completion = try #require(output.completions.last)
        completion()
        #expect(player.snapshot.status == .idle)
        #expect(output.buffers == [[0.25], [0.25]])
    }

    @Test
    func oldAudioInterruptionCannotStopANewSession() throws {
        let output = SilentSpeechOutput()
        let player = SpeechPlayer(output: output)
        try player.read(owner: owner, content: "First response.", service: WaitingSpeechService())
        let oldInterruption = try #require(output.interruptions.first)
        let next = SpeechOwner(chatId: "chat", messageId: "next")
        try player.read(owner: next, content: "Next response.", service: WaitingSpeechService())
        oldInterruption(.interrupted)
        #expect(player.snapshot.owner == next)
        #expect(player.snapshot.status == .loading)
        player.stop()
        #expect(player.snapshot.status == .idle)
        #expect(player.snapshot.owner == nil)
    }

    @Test
    func invalidTextDoesNotReplaceCurrentPlayback() throws {
        let player = SpeechPlayer(output: SilentSpeechOutput())
        try player.read(owner: owner, content: "First response.", service: WaitingSpeechService())
        let next = SpeechOwner(chatId: "chat", messageId: "next")
        #expect(throws: SpeechError.empty) {
            try player.read(owner: next, content: "```swift\ncode()\n```", service: WaitingSpeechService())
        }
        #expect(throws: SpeechError.tooLong) {
            try player.read(owner: next, content: String(repeating: "x", count: Constants.Speech.maxTextCharacters + 1), service: WaitingSpeechService())
        }
        #expect(player.snapshot.owner == owner)
        #expect(player.snapshot.status == .loading)
        player.stop()
    }

    @Test
    func messageChangesDeletionAndNavigationInvalidatePlayback() throws {
        let player = SpeechPlayer(output: SilentSpeechOutput())
        let message = Message(id: owner.messageId, role: .assistant, content: "Original response.")
        func start() throws {
            try player.read(owner: owner, content: message.content, service: WaitingSpeechService())
        }
        try start()
        player.reconcile(chatId: owner.chatId, messages: [message, Message(role: .user, content: "Another question")])
        #expect(player.snapshot.owner == owner)
        var changed = message
        changed.content = "Replaced response."
        player.reconcile(chatId: owner.chatId, messages: [changed])
        #expect(player.snapshot.status == .idle)
        try start()
        player.reconcile(chatId: owner.chatId, messages: [])
        #expect(player.snapshot.status == .idle)
        try start()
        player.reconcile(chatId: "other-chat", messages: [message])
        #expect(player.snapshot.status == .idle)
    }

    @Test
    func audioSetupFailureKeepsOnlyASafeRetryableError() throws {
        let output = SilentSpeechOutput()
        output.preparationError = .audioBusy
        let player = SpeechPlayer(output: output)
        try player.read(owner: owner, content: "Answer.", service: WaitingSpeechService())
        #expect(player.snapshot.owner == owner)
        #expect(player.snapshot.status == .failed(.audioBusy))
        player.reconcile(chatId: nil, messages: [])
        #expect(player.snapshot.status == .idle)
    }

    @Test
    func failuresRemainPendingUntilAcknowledgedAndResetForEachAttempt() throws {
        let output = SilentSpeechOutput()
        output.preparationError = .audioBusy
        let player = SpeechPlayer(output: output)
        let other = SpeechOwner(chatId: owner.chatId, messageId: "other-message")
        try player.read(owner: owner, content: "Answer.", service: WaitingSpeechService())
        #expect(player.pendingFailure(for: owner) == .audioBusy)
        #expect(player.pendingFailure(for: other) == nil)
        player.acknowledgeFailure(for: other)
        #expect(player.pendingFailure(for: owner) == .audioBusy)
        player.acknowledgeFailure(for: owner)
        #expect(player.pendingFailure(for: owner) == nil)
        #expect(player.snapshot.status == .failed(.audioBusy))

        try player.read(owner: owner, content: "Answer.", service: WaitingSpeechService())
        #expect(player.pendingFailure(for: owner) == .audioBusy)
        player.stop()
        #expect(player.pendingFailure(for: owner) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopCancelsTheActiveProducer() async throws {
        let service = WaitingSpeechService()
        let player = SpeechPlayer(output: SilentSpeechOutput())
        var started = service.started.makeAsyncIterator()
        var canceled = service.canceled.makeAsyncIterator()
        try player.read(owner: owner, content: "Answer.", service: service)
        _ = await started.next()
        player.stop()
        _ = await canceled.next()
        #expect(player.snapshot.status == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func releasingThePlayerDoesNotLeaveGenerationAlive() async throws {
        let service = WaitingSpeechService()
        let output = SilentSpeechOutput()
        var player: SpeechPlayer? = SpeechPlayer(output: output)
        weak var releasedPlayer = player
        var started = service.started.makeAsyncIterator()
        var canceled = service.canceled.makeAsyncIterator()
        try player?.read(owner: owner, content: "Answer.", service: service)
        _ = await started.next()
        let (stopped, stopContinuation) = AsyncStream<Void>.makeStream()
        defer { stopContinuation.finish() }
        output.onStop = { stopContinuation.yield(()) }
        var stoppedIterator = stopped.makeAsyncIterator()
        player = nil
        _ = await canceled.next()
        _ = await stoppedIterator.next()
        #expect(releasedPlayer == nil)
    }
}

@MainActor
private final class SilentSpeechOutput: SpeechAudioPlaying {
    var interruptions: [@MainActor (SpeechError?) -> Void] = []
    var preparationError: SpeechError?
    var completions: [@MainActor @Sendable () -> Void] = []
    var buffers: [[Float]] = []
    var onStop: (@MainActor () -> Void)?
    private let scheduledEvents = AsyncStream<Void>.makeStream()
    var scheduled: AsyncStream<Void> { scheduledEvents.stream }

    func prepare(onInterruption: @escaping @MainActor (SpeechError?) -> Void) throws {
        if let preparationError { throw preparationError }
        interruptions.append(onInterruption)
    }
    func schedule(_ samples: [Float], completion: @escaping @MainActor @Sendable () -> Void) throws {
        buffers.append(samples)
        completions.append(completion)
        scheduledEvents.continuation.yield(())
    }
    func play() {}
    func pause() {}
    func stop() { onStop?() }
}

private struct ShortSpeechService: SpeechSynthesizing {
    func generate(_ text: String, receive: @escaping @Sendable ([Float]) async throws -> Void) async throws {
        try await receive([0.25])
    }
}

private struct WaitingSpeechService: SpeechSynthesizing {
    let started: AsyncStream<Void>
    let canceled: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let canceledContinuation: AsyncStream<Void>.Continuation

    init() {
        let start = AsyncStream<Void>.makeStream()
        started = start.stream
        startedContinuation = start.continuation
        let cancel = AsyncStream<Void>.makeStream()
        canceled = cancel.stream
        canceledContinuation = cancel.continuation
    }

    func generate(_ text: String, receive: @escaping @Sendable ([Float]) async throws -> Void) async throws {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        continuation.onTermination = { [canceledContinuation] termination in
            if case .cancelled = termination { canceledContinuation.yield(()) }
        }
        defer { continuation.finish() }
        startedContinuation.yield(())
        for try await samples in stream { try await receive(samples) }
    }
}
