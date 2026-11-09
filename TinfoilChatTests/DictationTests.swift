import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct DictationTests {
    private static let maximumPolls = 500
    private static let pollInterval: Duration = .milliseconds(10)
    private static let chat = "chat"

    private struct ConditionNeverMet: Error {}

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
        let heard = Heard()
        let gate = Gate()
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
        dictation.recorded(try recording("first"), chatId: Self.chat, dictationId: "dictation", index: 0, startedAt: startedAt, persist: true)
        dictation.recorded(try recording("second"), chatId: Self.chat, dictationId: "dictation", index: 1, startedAt: startedAt, persist: true)

        try await until { heard.recordings.count == 3 && !dictation.state.transcribing }
        #expect(dictation.state.retrying == 1)
        #expect(dictation.state.readyChatIds.isEmpty)
        #expect(dictation.take(chatId: Self.chat).isEmpty)

        gate.open()
        try await until { dictation.state.readyChatIds == [Self.chat] && dictation.state.retrying == 0 }
        #expect(dictation.take(chatId: Self.chat) == ["First.", "Second."])
        #expect(dictation.state == Dictation.State())
    }

    @Test(.timeLimit(.minutes(1)))
    func aChatsDictationWaitsForThatChat() async throws {
        let dictation = Dictation(retryDelays: [])
        dictation.open(store: DictationStore(directory: try temporaryDirectory())) { recording, _ in
            self.words(recording).capitalized + "."
        }
        dictation.recorded(try recording("mine"), chatId: Self.chat, dictationId: "dictation", index: 0, startedAt: Date(), persist: true)
        try await until { dictation.state.readyChatIds == [Self.chat] }

        #expect(dictation.take(chatId: "another chat").isEmpty)
        #expect(dictation.take(chatId: Self.chat) == ["Mine."])
        #expect(dictation.take(chatId: Self.chat).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRecordingThatCouldNotBeTranscribedIsTranscribedAfterARelaunch() async throws {
        let directory = try temporaryDirectory()
        let dictation = Dictation(retryDelays: [])
        dictation.open(store: DictationStore(directory: directory)) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        dictation.recorded(try recording("kept"), chatId: Self.chat, dictationId: "dictation", index: 0, startedAt: Date(), persist: true)
        try await until { dictation.state.failed == 1 }
        try await until { await kept(in: directory) == ["kept"] }

        let relaunched = Dictation(retryDelays: [])
        relaunched.open(store: DictationStore(directory: directory)) { recording, _ in
            self.words(recording).capitalized + "."
        }
        try await until { relaunched.state.readyChatIds == [Self.chat] }
        #expect(relaunched.take(chatId: Self.chat) == ["Kept."])
        try await until { await DictationStore(directory: directory).load().isEmpty }
    }

    @Test(.timeLimit(.minutes(1)))
    func discardingARecordingThatFailedLetsTheTextAfterItThrough() async throws {
        let dictation = Dictation(retryDelays: [0])
        dictation.open(store: DictationStore(directory: try temporaryDirectory())) { recording, _ in
            let words = self.words(recording)
            if words == "unreadable" {
                throw HarnessError(code: "ATTACHMENT_UNSUPPORTED", message: "Unsupported recording type", action: .revise)
            }
            return words.capitalized + "."
        }
        let startedAt = Date()
        dictation.recorded(try recording("unreadable"), chatId: Self.chat, dictationId: "dictation", index: 0, startedAt: startedAt, persist: true)
        dictation.recorded(try recording("after"), chatId: Self.chat, dictationId: "dictation", index: 1, startedAt: startedAt, persist: true)

        try await until { dictation.state.failed == 1 && !dictation.state.transcribing }
        #expect(dictation.take(chatId: Self.chat).isEmpty)

        dictation.discardFailed()
        #expect(dictation.take(chatId: Self.chat) == ["After."])
        #expect(dictation.state == Dictation.State())
    }

    @Test(.timeLimit(.minutes(1)))
    func aCanceledDictationIsForgotten() async throws {
        let directory = try temporaryDirectory()
        let dictation = Dictation(retryDelays: [0])
        let heard = Heard()
        let gate = Gate()
        dictation.open(store: DictationStore(directory: directory)) { recording, _ in
            heard.recordings.append(self.words(recording))
            await gate.wait()
            return "Canceled."
        }
        dictation.recorded(try recording("canceled"), chatId: Self.chat, dictationId: "dictation", index: 0, startedAt: Date(), persist: true)
        try await until { heard.recordings == ["canceled"] }
        try await until { await kept(in: directory) == ["canceled"] }

        dictation.discard(dictationId: "dictation")
        gate.open()
        try await until { await DictationStore(directory: directory).load().isEmpty }
        #expect(dictation.take(chatId: Self.chat).isEmpty)
        #expect(dictation.state == Dictation.State())
    }

    @Test(.timeLimit(.minutes(1)))
    func aTemporaryChatsDictationIsNeverWrittenToTheDevice() async throws {
        let directory = try temporaryDirectory()
        let dictation = Dictation(retryDelays: [])
        dictation.open(store: DictationStore(directory: directory)) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        dictation.recorded(try recording("private"), chatId: "", dictationId: "temporary", index: 0, startedAt: Date(), persist: false)
        try await until { dictation.state.failed == 1 }

        // A dictation in a saved chat after it is kept, and it alone.
        dictation.recorded(try recording("kept"), chatId: Self.chat, dictationId: "saved", index: 0, startedAt: Date(), persist: true)
        try await until { dictation.state.failed == 2 }
        try await until { await kept(in: directory) == ["kept"] }
    }
}
