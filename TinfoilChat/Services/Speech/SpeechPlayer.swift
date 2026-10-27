import Combine
import Foundation

struct SpeechOwner: Equatable, Sendable {
    let chatId: String
    let messageId: String
}

@MainActor
final class SpeechPlayer: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case playing
        case failed(SpeechError)
    }

    struct Snapshot: Equatable {
        var owner: SpeechOwner? = nil
        var status: Status = .idle
    }

    /// One message read aloud: the chat service streams its audio as one
    /// response, which plays as it arrives.
    private final class Session {
        let id: UUID
        let owner: SpeechOwner
        let source: String
        let service: any SpeechSynthesizing
        var buffer = SpeechBuffer(chunkCount: 1)
        /// The stream is not read further while too much audio waits to
        /// play; playback wakes it.
        var drained: CheckedContinuation<Void, Never>?

        init(id: UUID, owner: SpeechOwner, source: String, service: any SpeechSynthesizing) {
            self.id = id
            self.owner = owner
            self.source = source
            self.service = service
        }
    }

    @Published private(set) var snapshot = Snapshot()
    private var session: Session?
    private var task: Task<Void, Never>?
    private let output: any SpeechAudioPlaying
    private var failureAcknowledged = false

    init(output: (any SpeechAudioPlaying)? = nil) {
        self.output = output ?? SpeechAudioOutput()
    }

    deinit {
        task?.cancel()
        let output = self.output
        Task { @MainActor in output.stop() }
    }

    /// Reads a message aloud. Its text is kept to notice the message
    /// changing under the narration.
    func read(owner: SpeechOwner, content: String, service: any SpeechSynthesizing) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechError.empty }
        stop()
        let id = UUID()
        session = Session(id: id, owner: owner, source: content, service: service)
        update(owner: owner, status: .loading)
        guard session?.id == id else { return }
        do {
            try output.prepare { [weak self] error in
                guard self?.session?.id == id else { return }
                if let error { self?.fail(error, sessionId: id) }
                else { self?.stop() }
            }
            pump(sessionId: id)
        } catch {
            fail(error, sessionId: id)
        }
    }

    func stop() {
        let ended = session
        session = nil
        failureAcknowledged = false
        task?.cancel()
        task = nil
        ended?.drained?.resume()
        ended?.drained = nil
        output.stop()
        update(owner: nil, status: .idle)
    }

    /// Stops narration that is preparing or playing, for app-wide shortcuts
    /// such as VoiceOver's Magic Tap that are not tied to a message. Returns
    /// false when nothing is audible so the gesture can fall through, and
    /// leaves a pending failure in place for its message's button to report.
    @discardableResult
    func stopIfActive() -> Bool {
        switch snapshot.status {
        case .loading, .playing:
            stop()
            return true
        case .idle, .failed:
            return false
        }
    }

    func pendingFailure(for owner: SpeechOwner) -> SpeechError? {
        guard snapshot.owner == owner, !failureAcknowledged,
              case .failed(let error) = snapshot.status else { return nil }
        return error
    }

    func acknowledgeFailure(for owner: SpeechOwner) {
        if pendingFailure(for: owner) != nil { failureAcknowledged = true }
    }

    func reconcile(chatId: String?, messages: [Message]) {
        guard let owner = snapshot.owner else { return }
        guard owner.chatId == chatId,
              let message = messages.first(where: { $0.id == owner.messageId }),
              SpeechTextProcessor.canRead(message) else {
            stop()
            return
        }
        if let session, SpeechTextProcessor.source(for: message) != session.source { stop() }
    }

    private func pump(sessionId: UUID) {
        guard let session, session.id == sessionId else { return }
        let blocks = session.buffer.takePlayableBlocks()
        if session.buffer.isFinished {
            stop()
            return
        }
        do {
            for block in blocks {
                let index = block.chunkIndex
                let sampleCount = block.samples.count
                try output.schedule(block.samples) { [weak self] in
                    guard self?.session?.id == sessionId else { return }
                    self?.session?.buffer.didPlay(chunkIndex: index, sampleCount: sampleCount)
                    self?.pump(sessionId: sessionId)
                }
                guard self.session?.id == sessionId else { return }
            }
            if session.buffer.isPlaying {
                output.play()
            } else {
                output.pause()
            }
            guard self.session?.id == sessionId else { return }
            update(owner: session.owner, status: session.buffer.isPlaying ? .playing : .loading)
            guard self.session?.id == sessionId else { return }
            if !session.buffer.isFull, let drained = session.drained {
                session.drained = nil
                drained.resume()
            }
            let indices = session.buffer.reserveRequests()
            guard let index = indices.first else { return }
            let service = session.service
            task = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    try await service.generate { [weak self] samples in
                        try await self?.receive(samples, index: index, sessionId: sessionId)
                    }
                    try Task.checkCancellation()
                    guard let self, self.session?.id == sessionId else { return }
                    self.task = nil
                    try self.session?.buffer.finishRequest(index)
                    self.pump(sessionId: sessionId)
                } catch {
                    guard let self, self.session?.id == sessionId else { return }
                    self.fail(error, sessionId: sessionId)
                }
            }
        } catch {
            fail(error, sessionId: sessionId)
        }
    }

    /// Takes a block of the stream's audio, and holds the stream while
    /// enough audio waits to play.
    private func receive(_ samples: [Float], index: Int, sessionId: UUID) async throws {
        guard let session, session.id == sessionId, !Task.isCancelled else { throw CancellationError() }
        try session.buffer.append(samples, to: index)
        pump(sessionId: sessionId)
        while let session = self.session, session.id == sessionId, session.buffer.isFull {
            await withCheckedContinuation { continuation in
                session.drained?.resume()
                session.drained = continuation
            }
        }
        guard self.session?.id == sessionId, !Task.isCancelled else { throw CancellationError() }
    }

    private func fail(_ error: Error, sessionId: UUID) {
        guard let session, session.id == sessionId else { return }
        let owner = session.owner
        stop()
        update(owner: owner, status: .failed(SpeechError.sanitized(error)))
    }

    private func update(owner: SpeechOwner?, status: Status) {
        let next = Snapshot(owner: owner, status: status)
        if snapshot != next { snapshot = next }
    }
}
