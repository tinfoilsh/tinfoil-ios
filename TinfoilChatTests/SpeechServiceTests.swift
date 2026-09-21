import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

struct SpeechServiceTests {
    @Test
    func encodesTheWebappsSpeechConfiguration() throws {
        let text = "Read this response."
        let data = try JSONEncoder().encode(SpeechService.query(for: text))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "qwen3-tts")
        #expect(body["voice"] as? String == "aiden")
        #expect(body["input"] as? String == text)
        #expect(body["instructions"] as? String == Constants.Speech.instructions)
        #expect(body["response_format"] as? String == "pcm")
        #expect(body["stream_format"] as? String == "audio")
    }

    @Test(.timeLimit(.minutes(1)))
    func consumesRealSDKResultsAndFlushesTheLastPartialBlock() async throws {
        let first = try Self.result([0x00])
        let second = try Self.result([0x80, 0xff, 0x7f])
        let service = SpeechService { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(first)
                continuation.yield(second)
                continuation.finish()
            }
        }
        let collector = SpeechSampleCollector()
        try await service.generate("Hello") { await collector.append($0) }
        #expect(await collector.blocks == [[-1, Float(Int16.max) / Constants.Speech.pcmScale]])
    }

    @Test(.timeLimit(.minutes(1)))
    func truncatedAudioFailsWithoutDeliveringThePartialSample() async throws {
        let result = try Self.result([0xff])
        let service = SpeechService { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(result)
                continuation.finish()
            }
        }
        let collector = SpeechSampleCollector()
        await #expect(throws: SpeechError.invalidAudio) {
            try await service.generate("Hello") { await collector.append($0) }
        }
        #expect(await collector.blocks.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineCancelsAStalledStream() async {
        let (stream, continuation) = AsyncThrowingStream<AudioSpeechResult, Error>.makeStream()
        defer { continuation.finish() }
        let service = SpeechService(timeout: .zero) { _ in stream }
        let collector = SpeechSampleCollector()
        await #expect(throws: SpeechError.timedOut) {
            try await service.generate("Hello") { await collector.append($0) }
        }
        #expect(await collector.blocks.isEmpty)
    }

    @Test
    func unknownErrorsNeverExposeProviderContent() {
        let error = NSError(domain: "provider", code: 1, userInfo: [NSLocalizedDescriptionKey: "private transcript and credentials"])
        #expect(SpeechError.sanitized(error) == .requestFailed)
        #expect(!SpeechError.sanitized(error).localizedDescription.contains("private transcript"))
        #expect(SpeechError.sanitized(AudioSpeechStreamError.unexpectedContentType("private data")) == .invalidAudio)
        #expect(SpeechError.sanitized(SessionTokenError.hourlyLimitReached(resetsAt: nil)) == .rateLimited)
    }

    private static func result(_ bytes: [UInt8]) throws -> AudioSpeechResult {
        let data = try JSONEncoder().encode(["audio": Data(bytes)])
        return try JSONDecoder().decode(AudioSpeechResult.self, from: data)
    }
}

private actor SpeechSampleCollector {
    private(set) var blocks: [[Float]] = []
    func append(_ samples: [Float]) { blocks.append(samples) }
}
