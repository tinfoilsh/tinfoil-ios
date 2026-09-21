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

    private final class Session {
        let id: UUID
        let owner: SpeechOwner
        let source: String
        let text: [String]
        let service: any SpeechSynthesizing
        var buffer: SpeechBuffer

        init(id: UUID, owner: SpeechOwner, source: String, text: [String], service: any SpeechSynthesizing) {
            self.id = id
            self.owner = owner
            self.source = source
            self.text = text
            self.service = service
            self.buffer = SpeechBuffer(chunkCount: text.count)
        }
    }

    @Published private(set) var snapshot = Snapshot()
    private var session: Session?
    private var tasks: [Int: Task<Void, Never>] = [:]
    private let output: any SpeechAudioPlaying
    private var failureAcknowledged = false

    init(output: (any SpeechAudioPlaying)? = nil) {
        self.output = output ?? SpeechAudioOutput()
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
        let output = self.output
        Task { @MainActor in output.stop() }
    }

    func read(owner: SpeechOwner, content: String, service: any SpeechSynthesizing) throws {
        let chunks = SpeechTextProcessor.split(try SpeechTextProcessor.prepare(content))
        guard !chunks.isEmpty else { throw SpeechError.empty }
        stop()
        let id = UUID()
        session = Session(id: id, owner: owner, source: content, text: chunks, service: service)
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
        session = nil
        failureAcknowledged = false
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        output.stop()
        update(owner: nil, status: .idle)
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
            let indices = session.buffer.reserveRequests()
            let service = session.service
            for index in indices {
                let text = session.text[index]
                tasks[index] = Task { [weak self] in
                    do {
                        try Task.checkCancellation()
                        try await service.generate(text) { [weak self] samples in
                            try await self?.receive(samples, index: index, sessionId: sessionId)
                        }
                        try Task.checkCancellation()
                        guard let self, self.session?.id == sessionId else { return }
                        self.tasks.removeValue(forKey: index)
                        try self.session?.buffer.finishRequest(index)
                        self.pump(sessionId: sessionId)
                    } catch {
                        guard let self, self.session?.id == sessionId else { return }
                        self.fail(error, sessionId: sessionId)
                    }
                }
            }
        } catch {
            fail(error, sessionId: sessionId)
        }
    }

    private func receive(_ samples: [Float], index: Int, sessionId: UUID) throws {
        guard session?.id == sessionId, !Task.isCancelled else { throw CancellationError() }
        try session?.buffer.append(samples, to: index)
        pump(sessionId: sessionId)
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
