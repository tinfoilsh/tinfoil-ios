import Foundation
import Testing
@testable import TinfoilChat

@Suite("Harness event stream")
struct HarnessEventStreamTests {
    private static let started = #"{"type":"RUN_STARTED","threadId":"t","runId":"r","instance":"i"}"#
    private static let finished = #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","metadata":{}}"#

    private static func chunks(_ parts: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(Data(part.utf8)) }
            continuation.finish()
        }
    }

    /// The bytes of `text`, split at every `every` bytes, so a chunk boundary
    /// falls inside characters, line breaks and fields.
    private static func bytes(_ text: String, every: Int) -> AsyncThrowingStream<Data, Error> {
        let all = Array(text.utf8)
        return AsyncThrowingStream { continuation in
            for start in stride(from: 0, to: all.count, by: every) {
                continuation.yield(Data(all[start..<min(start + every, all.count)]))
            }
            continuation.finish()
        }
    }

    private static func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> [Frame] {
        var frames: [Frame] = []
        for try await frame in HarnessEventStream.frames(from: stream) { frames.append(frame) }
        return frames
    }

    private static func failure(_ stream: AsyncThrowingStream<Data, Error>) async -> HarnessError? {
        do {
            _ = try await collect(stream)
            return nil
        } catch {
            return error as? HarnessError
        }
    }

    @Test(arguments: [1, 3, 7, 64])
    func readsFramesHoweverTheBytesAreChunked(every: Int) async throws {
        let text = "id: 0\r\ndata: \(Self.started)\r\n\r\n"
            + ": a comment the reader skips\n"
            + "id: 1\ndata: {\"type\":\"TEXT_MESSAGE_CHUNK\",\"messageId\":\"m\",\n"
            + "data: \"role\":\"assistant\",\"delta\":\"héllo — 🌍\"}\n\n"
            + "id: 2\ndata: \(Self.finished)\n\n"
        let frames = try await Self.collect(Self.bytes(text, every: every))
        #expect(frames.map(\.id) == [0, 1, 2])
        guard case .textMessageChunk(let chunk) = frames[1].event else {
            Issue.record("expected a text chunk, got \(frames[1].event)")
            return
        }
        #expect(chunk.delta == "héllo — 🌍")
        #expect(frames[2].event.isTerminal)
    }

    @Test func aStreamThatEndsBeforeTheRunIsInterrupted() async {
        let error = await Self.failure(Self.chunks(["id: 0\ndata: \(Self.started)\n\n", "id: 1\ndata: {\"type\":\"TEXT_MESSAGE_CHUNK\",\"messageId\":\"m\",\"role\":\"assistant\",\"delta\":\"x\"}\n\n"]))
        #expect(error?.code == HarnessErrorCode.streamInterrupted)
        #expect(error?.action == .retry)
    }

    @Test func anUnfinishedFrameAtTheEndIsNotDelivered() async {
        let error = await Self.failure(Self.chunks(["data: \(Self.started)\n\ndata: \(Self.finished)"]))
        #expect(error?.code == HarnessErrorCode.streamInterrupted)
    }

    @Test(arguments: ["-1", "1.5", "abc", "", "99999999999999999999"])
    func refusesACursorThatIsNotANonNegativeInteger(id: String) async {
        let error = await Self.failure(Self.chunks(["id: \(id)\ndata: \(Self.started)\n\n"]))
        #expect(error?.code == HarnessErrorCode.invalidStream)
        #expect(error?.action == .stop)
    }

    @Test func refusesDataThatIsNotAnEvent() async {
        let error = await Self.failure(Self.chunks(["data: {\"delta\": \"no type\"}\n\n"]))
        #expect(error?.code == HarnessErrorCode.invalidStream)
    }

    @Test func refusesAKnownEventThatDoesNotReadAsDescribed() async {
        let error = await Self.failure(Self.chunks(["data: {\"type\":\"RUN_STARTED\",\"threadId\":\"t\"}\n\n"]))
        #expect(error?.code == HarnessErrorCode.invalidStream)
        #expect(error?.detail.message.contains("RUN_STARTED") == true)
    }

    @Test func ignoresAnEventOfATypeItDoesNotKnow() async throws {
        let frames = try await Self.collect(Self.chunks([
            "id: 0\ndata: \(Self.started)\n\n",
            "id: 1\ndata: {\"type\":\"LATER_EVENT\",\"anything\":true}\n\n",
            "id: 2\ndata: \(Self.finished)\n\n",
        ]))
        #expect(frames.map(\.id) == [0, 2])
    }

    @Test func readsARunErrorWithACodeAndActionItDoesNotKnow() async throws {
        let frames = try await Self.collect(Self.chunks([
            "data: {\"type\":\"RUN_ERROR\",\"threadId\":\"t\",\"runId\":\"r\",\"code\":\"LATER_CODE\",\"message\":\"m\",\"action\":\"later_action\",\"retryAfter\":5}\n\n",
        ]))
        guard case .runError(let failed) = frames[0].event else {
            Issue.record("expected a run error, got \(frames[0].event)")
            return
        }
        #expect(failed.error == HarnessErrorBody(code: "LATER_CODE", message: "m", action: .stop, retryAfter: 5))
        #expect(failed.runId == "r")
    }

    @Test func refusesAFrameBeyondTheSizeLimit() async {
        let oversized = String(repeating: "x", count: HarnessEventStream.maximumFrameBytes + 1)
        let error = await Self.failure(Self.chunks(["data: {\"type\":\"TEXT_MESSAGE_CHUNK\",\"delta\":\"\(oversized)"]))
        #expect(error?.code == HarnessErrorCode.invalidStream)
    }

    @Test func aTransportFailureEndsTheStreamWithIt() async {
        struct Dropped: Error {}
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("id: 0\ndata: \(Self.started)\n\n".utf8))
            continuation.finish(throwing: Dropped())
        }
        do {
            _ = try await Self.collect(stream)
            Issue.record("the stream did not fail")
        } catch {
            #expect(error is Dropped)
        }
    }
}
