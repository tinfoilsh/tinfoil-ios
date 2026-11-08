import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct DictationTests {
    private static let maximumPolls = 500
    private static let pollInterval: Duration = .milliseconds(10)

    private struct ConditionNeverMet: Error {}

    /// The text the composer received, in order.
    private final class Received {
        var texts: [String] = []
    }

    /// What the chat service was asked to transcribe, in order.
    private final class Heard {
        var recordings: [String] = []
    }

    /// Holds a transcription until the test lets it answer.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A recording file holding what the microphone heard.
    private func recording(_ words: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(Constants.Audio.recordingFileExtension)
        try Data(words.utf8).write(to: url)
        return url
    }

    /// The recordings kept in the directory that wait to be transcribed.
    private func kept(in directory: URL) async -> [String] {
        await DictationStore(directory: directory).load()
            .compactMap { kept in kept.audio.map { String(decoding: $0, as: UTF8.self) } }
            .sorted()
    }

    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<Self.maximumPolls {
            if await condition() { return }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ConditionNeverMet()
    }

    private func words(_ recording: Data) -> String {
        String(decoding: recording, as: UTF8.self)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRecordingTriedAgainKeepsItsPlaceBeforeTheNextOne() async throws {
        let dictation = Dictation(retryDelays: [0])
        let received = Received()
        let heard = Heard()
        let gate = Gate()
        dictation.onText = { received.texts.append($0) }
        dictation.open(store: DictationStore(directory: try temporaryDirectory())) { recording, _ in
            let words = self.words(recording)
            heard.recordings.append(words)
            if words == "first" {
                // The first attempt fails; the one after it waits for the test.
                if heard.recordings.filter({ $0 == "first" }).count == 1 { throw URLError(.networkConnectionLost) }
                await gate.wait()
            }
            return words.capitalized + "."
        }
        let startedAt = Date()
        dictation.recorded(try recording("first"), dictationId: "dictation", index: 0, startedAt: startedAt, persist: true)
        dictation.recorded(try recording("second"), dictationId: "dictation", index: 1, startedAt: startedAt, persist: true)

        try await until { heard.recordings.count == 3 && !dictation.state.transcribing }
        #expect(dictation.state.retrying == 1)
        #expect(received.texts.isEmpty)

        gate.open()
        try await until { received.texts.count == 2 }
        #expect(received.texts == ["First.", "Second."])
        #expect(dictation.state == Dictation.State())
    }

    @Test(.timeLimit(.minutes(1)))
    func aRecordingThatCouldNotBeTranscribedIsTranscribedAfterARelaunch() async throws {
        let directory = try temporaryDirectory()
        let dictation = Dictation(retryDelays: [])
        dictation.open(store: DictationStore(directory: directory)) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        dictation.recorded(try recording("kept"), dictationId: "dictation", index: 0, startedAt: Date(), persist: true)
        try await until { dictation.state.failed == 1 }
        try await until { await kept(in: directory) == ["kept"] }

        let relaunched = Dictation(retryDelays: [])
        let received = Received()
        relaunched.onText = { received.texts.append($0) }
        relaunched.open(store: DictationStore(directory: directory)) { recording, _ in
            self.words(recording).capitalized + "."
        }
        try await until { received.texts == ["Kept."] }
        try await until { await DictationStore(directory: directory).load().isEmpty }
    }

    @Test(.timeLimit(.minutes(1)))
    func discardingARecordingThatFailedLetsTheTextAfterItThrough() async throws {
        let dictation = Dictation(retryDelays: [0])
        let received = Received()
        dictation.onText = { received.texts.append($0) }
        dictation.open(store: DictationStore(directory: try temporaryDirectory())) { recording, _ in
            let words = self.words(recording)
            if words == "unreadable" {
                throw HarnessError(code: "ATTACHMENT_UNSUPPORTED", message: "Unsupported recording type", action: .revise)
            }
            return words.capitalized + "."
        }
        let startedAt = Date()
        dictation.recorded(try recording("unreadable"), dictationId: "dictation", index: 0, startedAt: startedAt, persist: true)
        dictation.recorded(try recording("after"), dictationId: "dictation", index: 1, startedAt: startedAt, persist: true)

        try await until { dictation.state.failed == 1 && !dictation.state.transcribing }
        #expect(received.texts.isEmpty)

        dictation.discardFailed()
        #expect(received.texts == ["After."])
        #expect(dictation.state == Dictation.State())
    }

    @Test(.timeLimit(.minutes(1)))
    func aCanceledDictationIsForgotten() async throws {
        let directory = try temporaryDirectory()
        let dictation = Dictation(retryDelays: [0])
        let received = Received()
        let heard = Heard()
        let gate = Gate()
        dictation.onText = { received.texts.append($0) }
        dictation.open(store: DictationStore(directory: directory)) { recording, _ in
            heard.recordings.append(self.words(recording))
            await gate.wait()
            return "Canceled."
        }
        dictation.recorded(try recording("canceled"), dictationId: "dictation", index: 0, startedAt: Date(), persist: true)
        try await until { heard.recordings == ["canceled"] }

        dictation.discard(dictationId: "dictation")
        gate.open()
        try await until { await DictationStore(directory: directory).load().isEmpty }
        #expect(received.texts.isEmpty)
        #expect(dictation.state == Dictation.State())
    }

    @Test(.timeLimit(.minutes(1)))
    func aTemporaryChatsDictationIsNeverWrittenToTheDevice() async throws {
        let directory = try temporaryDirectory()
        let dictation = Dictation(retryDelays: [])
        dictation.open(store: DictationStore(directory: directory)) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        dictation.recorded(try recording("private"), dictationId: "temporary", index: 0, startedAt: Date(), persist: false)
        try await until { dictation.state.failed == 1 }

        // A dictation in a saved chat after it is kept, and it alone.
        dictation.recorded(try recording("kept"), dictationId: "saved", index: 0, startedAt: Date(), persist: true)
        try await until { dictation.state.failed == 2 }
        try await until { await kept(in: directory) == ["kept"] }
    }
}
