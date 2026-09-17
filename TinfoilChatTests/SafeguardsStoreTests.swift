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
    func rejectsAResponseAfterSignOutEvenIfTheTransportIgnoresCancellation() async {
        let fetcher = ControlledFlagFetcher()
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        let refresh = Task { await store.refresh() }
        await fetcher.waitForRequests(1)
        store.setUserId(nil)
        fetcher.complete(0, report: Self.report(chatId: "old-chat"))
        await refresh.value

        #expect(store.report == nil)
        #expect(!store.isFlagged("old-chat"))
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test
    func oldRequestCannotClearOrReplaceANewAccountsRequest() async {
        let fetcher = ControlledFlagFetcher()
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        let old = Task { await store.refresh() }
        await fetcher.waitForRequests(1)
        store.setUserId("user-b")
        let new = Task { await store.refresh() }
        await fetcher.waitForRequests(2)

        fetcher.complete(0, report: Self.report(chatId: "old-chat"))
        await old.value
        #expect(store.report == nil)
        #expect(store.isLoading)

        fetcher.complete(1, report: Self.report(chatId: "new-chat"))
        await new.value
        #expect(!store.isFlagged("old-chat"))
        #expect(store.isFlagged("new-chat"))
        #expect(!store.isLoading)
        #expect(fetcher.requestedUsers == ["user-a", "user-b"])
    }

    @Test
    func refreshesShareTheSameInFlightRequest() async {
        let fetcher = ControlledFlagFetcher()
        let store = SafeguardsStore(usesExamples: false, fetchFlags: fetcher.fetch)
        store.setUserId("user-a")
        let first = Task { await store.refresh() }
        await fetcher.waitForRequests(1)
        let secondStarted = AsyncStream<Void>.makeStream()
        let second = Task {
            secondStarted.continuation.yield()
            await store.refresh()
        }
        for await _ in secondStarted.stream { break }

        #expect(fetcher.requestedUsers == ["user-a"])
        fetcher.complete(0, report: Self.report(chatId: "chat-a"))
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
            flags: [SafeguardFlag(id: chatId, conversationId: chatId, createdAt: Date())],
            inWindow: 1,
            windowHours: 168,
            warnThreshold: 8,
            banThreshold: 10
        )
    }
}

@MainActor
private final class ControlledFlagFetcher {
    private(set) var requestedUsers: [String] = []
    private var pending: [Int: CheckedContinuation<SafeguardFlagsReport, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func fetch(_ userId: String) async -> SafeguardFlagsReport {
        let index = requestedUsers.count
        requestedUsers.append(userId)
        return await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.0 <= requestedUsers.count }
            waiters.removeAll { $0.0 <= requestedUsers.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requestedUsers.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, report: SafeguardFlagsReport) {
        pending.removeValue(forKey: index)?.resume(returning: report)
    }
}
