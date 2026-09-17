import Foundation
import Testing
@testable import TinfoilChat

@MainActor
struct SafeguardsStoreTests {
    @Test
    func loadsFlagsOnlyForASignedInAccountAndClearsThemOnSignOut() async {
        var requestedUsers: [String] = []
        let store = SafeguardsStore(usesExamples: false) { userId in
            requestedUsers.append(userId)
            return Self.report(chatId: "chat-a")
        }

        await store.refresh()
        #expect(store.report == nil)
        #expect(requestedUsers.isEmpty)

        store.setUserId("user-a")
        await store.refresh()
        #expect(requestedUsers == ["user-a"])
        #expect(store.isFlagged("chat-a"))
        #expect(!store.isFlagged("flag-for-chat-a"))
        #expect(store.report?.remaining == 9)

        store.setUserId(nil)
        #expect(store.report == nil)
        #expect(!store.isFlagged("chat-a"))
        #expect(store.errorMessage == nil)
    }

    @Test
    func retainsSameAccountDataOnRefreshFailureButNotOnAccountChange() async {
        var shouldFail = false
        let store = SafeguardsStore(usesExamples: false) { _ in
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return Self.report(chatId: "chat-a")
        }
        store.setUserId("user-a")
        await store.refresh()
        shouldFail = true
        await store.refresh()

        #expect(store.isFlagged("chat-a"))
        #expect(store.errorMessage == Constants.Safeguards.loadError)
        #expect(!store.isLoading)

        store.setUserId("user-b")
        #expect(store.report == nil)
        #expect(!store.isFlagged("chat-a"))
        #expect(store.errorMessage == nil)
        await store.refresh()
        #expect(store.report == nil)
        #expect(store.errorMessage != nil)
    }

    @Test
    func rejectsAResponseAfterSignOutEvenIfTheTransportIgnoresCancellation() async throws {
        let fetcher = ControlledFlagFetcher()
        defer { fetcher.cancelAll() }
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        let refresh = Task { await store.refresh() }
        try await fetcher.waitForRequests(1)
        store.setUserId(nil)
        try fetcher.complete(0, report: Self.report(chatId: "old-chat"))
        await refresh.value

        #expect(store.report == nil)
        #expect(!store.isFlagged("old-chat"))
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test
    func oldRequestCannotClearOrReplaceANewAccountsRequest() async throws {
        let fetcher = ControlledFlagFetcher()
        defer { fetcher.cancelAll() }
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        let old = Task { await store.refresh() }
        try await fetcher.waitForRequests(1)
        store.setUserId("user-b")
        let new = Task { await store.refresh() }
        try await fetcher.waitForRequests(2)

        try fetcher.complete(0, report: Self.report(chatId: "old-chat"))
        await old.value
        #expect(store.report == nil)
        #expect(store.isLoading)

        try fetcher.complete(1, report: Self.report(chatId: "new-chat"))
        await new.value
        #expect(!store.isFlagged("old-chat"))
        #expect(store.isFlagged("new-chat"))
        #expect(!store.isLoading)
        #expect(fetcher.requestedUsers == ["user-a", "user-b"])
    }

    @Test
    func newSessionStartsItsOwnRequestForTheSameAccount() async throws {
        let fetcher = ControlledFlagFetcher()
        defer { fetcher.cancelAll() }
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        store.setSessionId("session-old")
        let old = Task { await store.refresh() }
        try await fetcher.waitForRequests(1)

        store.setSessionId("session-new")
        let new = Task { await store.refresh() }
        try await fetcher.waitForRequests(2)
        try fetcher.complete(0, report: Self.report(chatId: "old-chat"))
        await old.value
        #expect(store.report == nil)
        #expect(store.errorMessage == nil)
        #expect(store.isLoading)

        try fetcher.complete(1, report: Self.report(chatId: "new-chat"))
        await new.value
        #expect(store.isFlagged("new-chat"))
        #expect(!store.isFlagged("old-chat"))
        #expect(!store.isLoading)
        #expect(fetcher.requestedUsers == ["user-a", "user-a"])
    }

    @Test
    func refreshesShareTheSameInFlightRequest() async throws {
        let fetcher = ControlledFlagFetcher()
        defer { fetcher.cancelAll() }
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        let first = Task { await store.refresh() }
        try await fetcher.waitForRequests(1)
        let secondStarted = AsyncStream<Void>.makeStream()
        let second = Task {
            secondStarted.continuation.yield()
            await store.refresh()
        }
        for await _ in secondStarted.stream { break }

        #expect(fetcher.requestedUsers == ["user-a"])
        try fetcher.complete(0, report: Self.report(chatId: "chat-a"))
        await first.value
        await second.value
        #expect(store.isFlagged("chat-a"))
    }

    #if DEBUG
    @Test
    func examplesAreAccountGatedAndSeparateFromLiveData() async {
        var requests = 0
        let store = SafeguardsStore(usesExamples: true) { _ in
            requests += 1
            return Self.report(chatId: "live-chat")
        }
        await store.refresh()
        #expect(store.report == nil)

        store.setUserId("user-a")
        await store.refresh()
        #expect(requests == 0)
        #expect(store.report?.flags.count == 3)
        #expect(store.report?.inWindow == 2)

        store.setUsesExamples(false)
        #expect(store.report == nil)
        await store.refresh()
        #expect(requests == 1)
        #expect(store.isFlagged("live-chat"))
        #expect(store.report?.flags.count == 1)
    }
    #endif

    private static func report(chatId: String) -> SafeguardFlagsReport {
        SafeguardFlagsReport(
            flags: [SafeguardFlag(id: "flag-for-\(chatId)", conversationId: chatId, createdAt: Date())],
            inWindow: 1,
            windowHours: 168,
            warnThreshold: 8,
            banThreshold: 10
        )
    }
}

@MainActor
private final class ControlledFlagFetcher {
    private static let requestTimeout: Duration = .seconds(5)
    private enum WaitError: Error {
        case requestNotStarted(Int)
        case responseNotCompleted(Int)
    }
    private(set) var requestedUsers: [String] = []
    private var pending: [Int: CheckedContinuation<SafeguardFlagsReport, Error>] = [:]
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Error>)] = [:]

    func fetch(_ userId: String) async throws -> SafeguardFlagsReport {
        let index = requestedUsers.count
        requestedUsers.append(userId)
        let timeout = Task {
            do {
                try await Task.sleep(for: Self.requestTimeout)
            } catch { return }
            pending.removeValue(forKey: index)?.resume(throwing: WaitError.responseNotCompleted(index))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.value.count <= requestedUsers.count }
            for (id, waiter) in ready {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume()
            }
        }
    }

    func waitForRequests(_ count: Int) async throws {
        if requestedUsers.count >= count { return }
        let id = UUID()
        let timeout = Task {
            do {
                try await Task.sleep(for: Self.requestTimeout)
            } catch { return }
            waiters.removeValue(forKey: id)?.continuation.resume(throwing: WaitError.requestNotStarted(count))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { waiters[id] = (count, $0) }
    }

    func complete(_ index: Int, report: SafeguardFlagsReport) throws {
        let continuation = try #require(pending.removeValue(forKey: index), "No pending request at index \(index)")
        continuation.resume(returning: report)
    }

    func cancelAll() {
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.resume(throwing: CancellationError()) }
        let waiting = waiters.values
        waiters.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: CancellationError()) }
    }
}
