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

private actor UploadConcurrencyGate {
    struct Snapshot: Sendable {
        let started: [String]
        let active: Int
        let maximumActive: Int
    }

    private var started: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]

    func enter(_ chatId: String) async {
        active += 1
        maximumActive = max(maximumActive, active)
        started.append(chatId)
        let readyWaiters = startWaiters.filter { started.count >= $0.0 }
        startWaiters.removeAll { started.count >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            releases[chatId] = continuation
        }
        active -= 1
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func release(_ chatId: String) {
        releases.removeValue(forKey: chatId)?.resume()
    }

    func snapshot() -> Snapshot {
        Snapshot(started: started, active: active, maximumActive: maximumActive)
    }
}

private actor PendingChatBackupProbe {
    private var pendingRequests = 0
    private var authoritativeReads: [String] = []

    func pendingChatIds() -> [String] {
        pendingRequests += 1
        return ["dirty-one", "dirty-two", "dirty-three"]
    }

    func upload(_ chatId: String) throws -> Bool {
        authoritativeReads.append(chatId)
        if chatId == "dirty-two" {
            throw UploadRetryTestError.terminal
        }
        return true
    }

    func snapshot() -> (Int, [String]) {
        (pendingRequests, authoritativeReads)
    }
}

private actor StartGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor SequentialBatchCancellationGate {
    private var started: [String] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var uploadContinuation: CheckedContinuation<Bool, Error>?

    func upload(_ chatId: String) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                started.append(chatId)
                uploadContinuation = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        } onCancel: {
            Task { await self.cancelUpload() }
        }
    }

    func waitForUploadStart() async {
        guard started.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func startedChatIds() -> [String] {
        started
    }

    private func cancelUpload() {
        uploadContinuation?.resume(throwing: CancellationError())
        uploadContinuation = nil
    }
}

struct CloudSyncUploadRetryTests {
    @Test
    func chatUploadsUseBoundedFIFOQueue() async {
        #expect(Constants.Sync.maxConcurrentChatUploads == 2)
        let gate = UploadConcurrencyGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { chatId, _, _ in
                await gate.enter(chatId)
                return { .uploaded }
            },
            waitBeforeRetry: { _ in }
        )

        await coalescer.enqueue("one")
        await coalescer.enqueue("two")
        await coalescer.enqueue("three")
        await coalescer.enqueue("four")
        await gate.waitForStarts(Constants.Sync.maxConcurrentChatUploads)
        var snapshot = await gate.snapshot()
        #expect(snapshot.started.count == Constants.Sync.maxConcurrentChatUploads)
        #expect(snapshot.maximumActive == Constants.Sync.maxConcurrentChatUploads)

        await gate.release("one")
        await gate.waitForStarts(3)
        snapshot = await gate.snapshot()
        #expect(snapshot.started[2] == "three")

        await gate.release("two")
        await gate.waitForStarts(4)
        snapshot = await gate.snapshot()
        #expect(snapshot.started[3] == "four")
        #expect(snapshot.maximumActive == Constants.Sync.maxConcurrentChatUploads)

        await gate.release("three")
        await gate.release("four")
        await coalescer.waitForUpload("four")
    }

    @Test
    func sameChatEditsStayCoalescedInOneWorker() async {
        let gate = UploadConcurrencyGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { chatId, _, _ in
                await gate.enter(chatId)
                return { .uploaded }
            },
            waitBeforeRetry: { _ in }
        )

        await coalescer.enqueue("chat")
        await gate.waitForStarts(1)
        await coalescer.enqueue("chat")
        await coalescer.enqueue("chat")
        await gate.release("chat")
        await gate.waitForStarts(2)
        var snapshot = await gate.snapshot()
        #expect(snapshot.started == ["chat", "chat"])
        #expect(snapshot.maximumActive == 1)

        await gate.release("chat")
        await coalescer.waitForUpload("chat")
        snapshot = await gate.snapshot()
        #expect(snapshot.started.count == 2)
    }

    @Test
    func cancellingWaiterDoesNotCancelSharedUpload() async {
        let gate = UploadConcurrencyGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { chatId, _, _ in
                await gate.enter(chatId)
                return { .uploaded }
            },
            waitBeforeRetry: { _ in }
        )
        let waiter = Task { try await coalescer.enqueueAndWait("chat") }
        await gate.waitForStarts(1)

        waiter.cancel()
        do {
            _ = try await waiter.value
            Issue.record("Expected waiter cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        var snapshot = await gate.snapshot()
        #expect(snapshot.active == 1)
        await gate.release("chat")
        await coalescer.waitForUpload("chat")
        snapshot = await gate.snapshot()
        #expect(snapshot.active == 0)
    }

    @Test
    func cancellationBeforeWaiterRegistrationDoesNotStartUpload() async {
        let startGate = StartGate()
        let uploadGate = UploadConcurrencyGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { chatId, _, _ in
                await uploadGate.enter(chatId)
                return { .uploaded }
            },
            waitBeforeRetry: { _ in }
        )
        let waiter = Task {
            await startGate.wait()
            return try await coalescer.enqueueAndWait("chat")
        }

        waiter.cancel()
        await startGate.release()
        do {
            _ = try await waiter.value
            Issue.record("Expected waiter cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let snapshot = await uploadGate.snapshot()
        #expect(snapshot.started.isEmpty)
        #expect(snapshot.active == 0)
    }

    @Test
    func clearImmediatelyProvidesFreshWorkerBudget() async {
        let gate = UploadConcurrencyGate()
        let coalescer = UploadCoalescer(
            prepareUpload: { chatId, _, _ in
                await gate.enter(chatId)
                return { .uploaded }
            },
            waitBeforeRetry: { _ in }
        )

        let staleWaiter = Task { try await coalescer.enqueueAndWait("old-one") }
        await coalescer.enqueue("old-two")
        await gate.waitForStarts(2)
        await coalescer.clear()
        await coalescer.enqueue("new-one")
        await coalescer.enqueue("new-two")
        await coalescer.enqueue("new-three")
        await gate.waitForStarts(4)
        var snapshot = await gate.snapshot()
        #expect(Set(snapshot.started) == Set(["old-one", "old-two", "new-one", "new-two"]))

        await gate.release("old-one")
        await gate.release("old-two")
        await Task.yield()
        snapshot = await gate.snapshot()
        #expect(!snapshot.started.contains("new-three"))

        await gate.release("new-one")
        await gate.waitForStarts(5)
        snapshot = await gate.snapshot()
        #expect(snapshot.started.last == "new-three")

        do {
            _ = try await staleWaiter.value
            Issue.record("Expected stale waiter cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await gate.release("new-two")
        await gate.release("new-three")
        await coalescer.waitForUpload("new-three")
    }

    @Test
    func bulkBackupUsesPendingIdsAndAuthoritativePerChatReads() async throws {
        let probe = PendingChatBackupProbe()

        let result = try await PendingChatBackupBatch.run(
            pendingChatIds: { await probe.pendingChatIds() },
            upload: { try await probe.upload($0) }
        )

        let snapshot = await probe.snapshot()
        #expect(snapshot.0 == 1)
        #expect(snapshot.1 == ["dirty-one", "dirty-two", "dirty-three"])
        #expect(result.uploaded == 2)
        #expect(result.errors.count == 1)
        #expect(result.failedChatIds == ["dirty-two"])
    }

    @Test
    func bulkBackupCancellationStopsBeforeNextChat() async {
        let gate = SequentialBatchCancellationGate()
        let batch = Task {
            try await PendingChatBackupBatch.run(
                pendingChatIds: { ["one", "two", "three"] },
                upload: { try await gate.upload($0) }
            )
        }
        await gate.waitForUploadStart()

        batch.cancel()
        do {
            _ = try await batch.value
            Issue.record("Expected batch cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await gate.startedChatIds() == ["one"])
    }

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
        type: "chat",
        chat: true,
        paid: false,
        multimodal: false,
        toolCalling: nil,
        chatConfig: ChatModelConfig(
            contextWindowTokens: 64_000,
            attributes: nil,
            descriptionShort: nil,
            reasoningConfig: nil
        )
    )
)
