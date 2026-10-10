import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

@MainActor
struct AudioTranscriptionTests {
    @Test(.timeLimit(.minutes(1)))
    func waitsForTokenBeforeSendingAudio() async throws {
        let file = try recordingFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AudioRecordingService()
        let preparing = AsyncStream<Void>.makeStream()
        let ready = AsyncStream<Void>.makeStream()
        var requestCount = 0
        var hasToken = false

        let task = Task {
            try await service.transcribe(
                fileURL: file,
                model: "test-audio",
                prepareRequest: { forceRefresh in
                    #expect(!forceRefresh)
                    preparing.continuation.yield(())
                    var iterator = ready.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    hasToken = true
                },
                request: { query in
                    requestCount += 1
                    #expect(hasToken)
                    #expect(query.file == Data([1, 2, 3]))
                    #expect(query.model == "test-audio")
                    #expect(query.fileType == .m4a)
                    #expect(query.responseFormat == .json)
                    return try result("  Hello world\n")
                },
                isAuthenticationError: ChatViewModel.isAuthenticationError
            )
        }

        var iterator = preparing.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(requestCount == 0)
        #expect(service.isTranscribing)
        ready.continuation.yield(())
        #expect(try await task.value == "Hello world")
        #expect(requestCount == 1)
        #expect(!service.isTranscribing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: ["missing_api_key", "invalid_api_key"])
    func authRetryPreservesAudioAndRefreshesToken(code: String) async throws {
        let file = try recordingFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AudioRecordingService()
        var refreshes: [Bool] = []
        var sentAudio: [Data] = []

        let text = try await service.transcribe(
            fileURL: file,
            model: "test-audio",
            prepareRequest: { refreshes.append($0) },
            request: { query in
                #expect(service.isTranscribing)
                #expect(FileManager.default.fileExists(atPath: file.path))
                sentAudio.append(query.file)
                if sentAudio.count == 1 { throw try apiError(code) }
                return try result("Recovered recording")
            },
            isAuthenticationError: ChatViewModel.isAuthenticationError
        )

        #expect(text == "Recovered recording")
        #expect(refreshes == [false, true])
        #expect(sentAudio == [Data([1, 2, 3]), Data([1, 2, 3])])
        #expect(!service.isTranscribing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: ["missing_api_key", "rate_limit_exceeded"])
    func terminalFailureCleansUpWithoutUnboundedRetries(code: String) async throws {
        let file = try recordingFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AudioRecordingService()
        var refreshes: [Bool] = []
        var requestCount = 0

        await #expect(throws: APIErrorResponse.self) {
            try await service.transcribe(
                fileURL: file,
                model: "test-audio",
                prepareRequest: { refreshes.append($0) },
                request: { _ in
                    requestCount += 1
                    throw try apiError(code)
                },
                isAuthenticationError: ChatViewModel.isAuthenticationError
            )
        }

        #expect(refreshes == (code == "missing_api_key" ? [false, true] : [false]))
        #expect(requestCount == refreshes.count)
        #expect(!service.isTranscribing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [false, true])
    func failedTokenAcquisitionDoesNotSendAnotherRequest(duringRetry: Bool) async throws {
        let file = try recordingFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AudioRecordingService()
        var requestCount = 0

        await #expect(throws: SessionTokenError.self) {
            try await service.transcribe(
                fileURL: file,
                model: "test-audio",
                prepareRequest: { forceRefresh in
                    if !duringRetry || forceRefresh {
                        throw SessionTokenError.hourlyLimitReached(resetsAt: nil)
                    }
                },
                request: { _ in
                    requestCount += 1
                    throw try apiError("missing_api_key")
                },
                isAuthenticationError: ChatViewModel.isAuthenticationError
            )
        }

        #expect(requestCount == (duringRetry ? 1 : 0))
        #expect(!service.isTranscribing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [false, true])
    func cancellationDuringTokenAcquisitionPreventsDispatch(duringRetry: Bool) async throws {
        let file = try recordingFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AudioRecordingService()
        var requestCount = 0

        let task = Task {
            try await service.transcribe(
                fileURL: file,
                model: "test-audio",
                prepareRequest: { forceRefresh in
                    if !duringRetry || forceRefresh {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                },
                request: { _ in
                    requestCount += 1
                    throw try apiError("invalid_api_key")
                },
                isAuthenticationError: ChatViewModel.isAuthenticationError
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(requestCount == (duringRetry ? 1 : 0))
        #expect(!service.isTranscribing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    private func recordingFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        try Data([1, 2, 3]).write(to: file)
        return file
    }

    private func result(_ text: String) throws -> AudioTranscriptionResult {
        try JSONDecoder().decode(AudioTranscriptionResult.self, from: JSONEncoder().encode(["text": text]))
    }

    private func apiError(_ code: String) throws -> APIErrorResponse {
        let data = try JSONEncoder().encode([
            "error": ["message": "Request rejected", "type": "invalid_request_error", "code": code]
        ])
        return try JSONDecoder().decode(APIErrorResponse.self, from: data)
    }
}
