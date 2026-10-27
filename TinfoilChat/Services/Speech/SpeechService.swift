import Foundation

protocol SpeechSynthesizing: Sendable {
    /// Streams a message's audio as blocks of samples until it ends.
    func generate(receive: @escaping @Sendable ([Float]) async throws -> Void) async throws
}

/// The audio the chat service reads a message aloud with: one stream of raw
/// PCM, mono, signed 16-bit little-endian at 24 kHz, decoded as it arrives.
struct HarnessSpeechStream: SpeechSynthesizing {
    typealias Open = @Sendable () async throws -> HarnessResponse
    let open: Open

    init(open: @escaping Open) {
        self.open = open
    }

    func generate(receive: @escaping @Sendable ([Float]) async throws -> Void) async throws {
        try Task.checkCancellation()
        let response = try await open()
        let mediaType = response.header("content-type")?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mediaType == Constants.Speech.contentType else { throw SpeechError.invalidAudio }
        var decoder = PCMStreamDecoder()
        for try await data in response.body {
            try Task.checkCancellation()
            for block in try decoder.decode(data) {
                try Task.checkCancellation()
                try await receive(block)
            }
        }
        try Task.checkCancellation()
        let tail = try decoder.finish()
        if !tail.isEmpty { try await receive(tail) }
    }
}
