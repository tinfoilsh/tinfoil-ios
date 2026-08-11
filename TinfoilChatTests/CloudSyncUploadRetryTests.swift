import Foundation
import Testing
@testable import TinfoilChat

private enum UploadRetryTestError: Error {
    case terminal
}

private actor RetryBackoffGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func pause() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor UploadRetryProbe {
    struct Snapshot: Sendable {
        let preparedKeys: [String]
        let executedKeys: [String]
        let allowWhileStreaming: [Bool]
    }

    private var preparedKeys: [String] = []
    private var executedKeys: [String] = []
    private var allowWhileStreaming: [Bool] = []

    func prepare(key: String, allowWhileStreaming: Bool) -> Int {
        preparedKeys.append(key)
        self.allowWhileStreaming.append(allowWhileStreaming)
        return preparedKeys.count
    }

    func execute(key: String, preparation: Int) throws {
        executedKeys.append(key)
        if preparation == 1 && executedKeys.count == 1 {
            throw SyncEnclaveError(message: "Unavailable", status: 503)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            preparedKeys: preparedKeys,
            executedKeys: executedKeys,
            allowWhileStreaming: allowWhileStreaming
        )
    }
}

struct CloudSyncUploadRetryTests {
    @Test
    func dirtyWriteDoesNotReplacePreparedRetry() async throws {
        let backoff = RetryBackoffGate()
        let probe = UploadRetryProbe()
        let coalescer = UploadCoalescer(
            prepareUpload: { _, key, allowWhileStreaming in
                let preparation = await probe.prepare(
                    key: key,
                    allowWhileStreaming: allowWhileStreaming
                )
                return {
                    try await probe.execute(key: key, preparation: preparation)
                    return .uploaded
                }
            },
            waitBeforeRetry: { _ in await backoff.pause() }
        )

        await coalescer.enqueue("chat", allowWhileStreaming: true)
        await backoff.waitUntilEntered()
        await coalescer.enqueue("chat")
        await backoff.release()
        await coalescer.waitForUpload("chat")

        let snapshot = await probe.snapshot()
        try #require(snapshot.preparedKeys.count == 2)
        try #require(snapshot.executedKeys.count == 3)
        #expect(snapshot.executedKeys[0] == snapshot.preparedKeys[0])
        #expect(snapshot.executedKeys[1] == snapshot.preparedKeys[0])
        #expect(snapshot.executedKeys[2] == snapshot.preparedKeys[1])
        #expect(snapshot.preparedKeys[0] != snapshot.preparedKeys[1])
        #expect(snapshot.allowWhileStreaming == [true, false])
    }

    @Test
    func clearDuringBackoffCancelsWaiterAndPreventsFrozenRetry() async {
        let backoff = RetryBackoffGate()
        let probe = UploadRetryProbe()
        let coalescer = UploadCoalescer(
            prepareUpload: { _, key, allowWhileStreaming in
                let preparation = await probe.prepare(
                    key: key,
                    allowWhileStreaming: allowWhileStreaming
                )
                return {
                    try await probe.execute(key: key, preparation: preparation)
                    return .uploaded
                }
            },
            waitBeforeRetry: { _ in await backoff.pause() }
        )
        let clearTask = Task {
            await backoff.waitUntilEntered()
            await coalescer.clear()
            await backoff.release()
        }
        var waiterCancelled = false

        do {
            try await coalescer.enqueueAndWait("chat")
            Issue.record("Expected clear to cancel the upload waiter")
        } catch is CancellationError {
            waiterCancelled = true
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        await clearTask.value
        await coalescer.waitForUpload("chat")

        let snapshot = await probe.snapshot()
        #expect(waiterCancelled)
        #expect(snapshot.preparedKeys.count == 1)
        #expect(snapshot.executedKeys.count == 1)
        #expect(snapshot.allowWhileStreaming == [false])
    }

    @Test func requiredUploadCannotSucceedWithoutPreparedWork() async {
        let coalescer = UploadCoalescer(
            prepareUpload: { _, _, _ in nil },
            waitBeforeRetry: { _ in }
        )

        do {
            try await coalescer.enqueueAndWait(
                "chat",
                allowWhileStreaming: true
            )
            Issue.record("Expected required upload preparation to fail")
        } catch UploadCoalescerError.requiredUploadNotPrepared {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func laterNoOpDoesNotClearRequiredUploadFailure() async {
        let backoff = RetryBackoffGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { _, _, allowWhileStreaming in
                guard allowWhileStreaming else { return nil }
                return { throw SyncEnclaveError(message: "Unavailable", status: 503) }
            },
            waitBeforeRetry: { _ in await backoff.pause() }
        )
        let waiter = Task {
            try await coalescer.enqueueAndWait(
                "chat",
                allowWhileStreaming: true
            )
        }
        await backoff.waitUntilEntered()
        await coalescer.enqueue("chat")
        await backoff.release()

        do {
            try await waiter.value
            Issue.record("Expected the earlier required upload failure")
        } catch let error as SyncEnclaveError {
            #expect(error.status == 503)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func laterActualUploadClearsRequiredUploadFailure() async {
        let backoff = RetryBackoffGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { _, _, allowWhileStreaming in
                if allowWhileStreaming {
                    return { throw SyncEnclaveError(message: "Unavailable", status: 503) }
                }
                return { .uploaded }
            },
            waitBeforeRetry: { _ in await backoff.pause() }
        )
        let waiter = Task {
            try await coalescer.enqueueAndWait(
                "chat",
                allowWhileStreaming: true
            )
        }
        await backoff.waitUntilEntered()
        await coalescer.enqueue("chat")
        await backoff.release()

        do {
            try await waiter.value
        } catch {
            Issue.record("Expected the later upload to clear the failure: \(error)")
        }
    }

    @Test @MainActor
    func frozenChatEncodingIsCanonical() throws {
        var chat = Chat(modelType: uploadRetryTestModel)
        chat.title = "Frozen"
        let frozen = StoredChat(from: chat, syncVersion: chat.syncVersion)

        let first = try CloudStorageService.encodeChatPlaintext(frozen)
        chat.title = "Newer edit"
        let replay = try CloudStorageService.encodeChatPlaintext(frozen)

        #expect(first == replay)
        #expect(String(decoding: first, as: UTF8.self).hasPrefix("{\"createdAt\":"))
    }

    @Test
    func attachmentIdempotencyKeyUsesFrozenIdentityAndBytes() {
        let plaintext = Data("image bytes".utf8)
        let first = CloudStorageService.attachmentIdempotencyKey(
            chatId: "chat",
            clientId: "attachment",
            plaintext: plaintext
        )
        let replay = CloudStorageService.attachmentIdempotencyKey(
            chatId: "chat",
            clientId: "attachment",
            plaintext: plaintext
        )
        let newerAttachment = CloudStorageService.attachmentIdempotencyKey(
            chatId: "chat",
            clientId: "attachment-2",
            plaintext: plaintext
        )

        #expect(first == replay)
        #expect(first != newerAttachment)
    }

    @Test
    func coalescerDoesNotRetryUnstructuredFailures() async {
        let probe = UploadRetryProbe()
        let coalescer = UploadCoalescer(
            prepareUpload: { _, key, allowWhileStreaming in
                _ = await probe.prepare(
                    key: key,
                    allowWhileStreaming: allowWhileStreaming
                )
                return {
                    throw UploadRetryTestError.terminal
                }
            },
            waitBeforeRetry: { _ in Issue.record("Terminal error was retried") }
        )

        do {
            try await coalescer.enqueueAndWait("terminal-chat")
            Issue.record("Expected terminal upload failure")
        } catch UploadRetryTestError.terminal {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let snapshot = await probe.snapshot()
        #expect(snapshot.preparedKeys.count == 1)
    }

    @Test func persistentAuthenticationIsTerminal() {
        let decision = EnclaveErrorRecovery.decide(.authenticationActionRequired)
        #expect(decision.action == .abort(reason: .authenticationRequired))
    }
}

private let uploadRetryTestModel = ModelType(
    from: AppModelConfig(
        modelName: "gpt-oss-120b",
        image: "openai.png",
        name: "GPT OSS 120B",
        nameShort: "GPT OSS",
        description: "",
        details: "",
        parameters: "",
        contextWindow: "64k tokens",
        type: "chat",
        chat: true,
        paid: false,
        multimodal: false,
        toolCalling: nil,
        attributes: nil,
        reasoningConfig: nil
    )
)
