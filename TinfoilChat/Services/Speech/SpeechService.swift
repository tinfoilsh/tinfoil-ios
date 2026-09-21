import Foundation
import OpenAI

protocol SpeechSynthesizing: Sendable {
    func generate(
        _ text: String,
        receive: @escaping @Sendable ([Float]) async throws -> Void
    ) async throws
}

struct SpeechService: SpeechSynthesizing {
    typealias StreamFactory = @MainActor @Sendable (String) async throws -> AsyncThrowingStream<AudioSpeechResult, Error>
    let makeStream: StreamFactory
    private let timeout: Duration

    init(timeout: Duration = .seconds(Constants.Speech.requestTimeoutSeconds), makeStream: @escaping StreamFactory) {
        self.timeout = timeout
        self.makeStream = makeStream
    }

    static func query(for text: String) -> AudioSpeechQuery {
        AudioSpeechQuery(
            model: Constants.Speech.model,
            input: text,
            voice: .custom(Constants.Speech.voice),
            instructions: Constants.Speech.instructions,
            responseFormat: .pcm,
            streamFormat: .audio
        )
    }

    func generate(
        _ text: String,
        receive: @escaping @Sendable ([Float]) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try Task.checkCancellation()
                let stream = try await makeStream(text)
                var decoder = PCMStreamDecoder()
                for try await result in stream {
                    try Task.checkCancellation()
                    for block in try decoder.decode(result.audio) {
                        try Task.checkCancellation()
                        try await receive(block)
                    }
                }
                try Task.checkCancellation()
                let tail = try decoder.finish()
                if !tail.isEmpty { try await receive(tail) }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SpeechError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
