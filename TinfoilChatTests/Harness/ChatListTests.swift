import Foundation
import Testing
@testable import TinfoilChat

private func summary(_ id: String, title: String = "Chat", pinned: Bool = false, projectId: String? = nil, at: String = "2026-01-01T00:00:00Z") -> ThreadSummary {
    ThreadSummary(
        id: id, title: title, titleState: .generated, createdAt: at, updatedAt: at, activityAt: at, projectId: projectId,
        model: "auto", webSearchEnabled: true, pinned: pinned, contextUsage: nil, activeRun: nil, messageCount: 1, flagged: nil
    )
}

private struct ListPage {
    static func json(_ threads: [ThreadSummary], pinned: [ThreadSummary]? = nil, next: String? = nil) -> ScriptedTransport.Answer {
        let encoder = JSONEncoder()
        var object: [String: Any] = [
            "threads": try! JSONSerialization.jsonObject(with: encoder.encode(threads)),
            "nextCursor": next.map { $0 as Any } ?? NSNull(),
        ]
        if let pinned { object["pinned"] = try! JSONSerialization.jsonObject(with: encoder.encode(pinned)) }
        return Answers.json(object)
    }
}

@Suite("Chat list")
@MainActor
struct ChatListTests {
    /// A list of an account with cloud sync, whose profile has loaded so its
    /// key is ready.
    private func makeList() async -> (ChatList, ScriptedTransport) {
        let transport = ScriptedTransport([Answers.json([:])])
        let credentials = ScriptedCredentials(identities: Array(repeating: "jwt", count: 10), access: Array(repeating: .success("k"), count: 10))
        let client = HarnessClient(credentials: credentials, transport: transport, languages: { [] })
        let account = HarnessAccount(
            userId: "u", client: client, credentials: HarnessCredentialProvider(
                identity: { _ in "jwt" },
                chatAccess: ChatAccessCache(controlPlane: NoControlPlane()) { _ in },
                anonymousAccess: AnonymousAccessCache(controlPlane: NoControlPlane())
            ),
            keyBytes: { Data(repeating: 1, count: 32) }, settings: MemoryProfileStorage(), cloudSync: true
        )
        let list = ChatList(account: account, device: DeviceThreadStore(directory: nil), cache: ChatListCache(directory: nil))
        await account.refreshProfile()
        #expect(account.keyReady)
        return (list, transport)
    }

    @Test func readsThePagesOfStoredChatsAndTheirFavorites() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a"), summary("b")], pinned: [summary("b", pinned: true)], next: "c2"))
        await transport.push(ListPage.json([summary("c")], next: nil))
        try await list.refresh()
        #expect(list.cloudListed.map(\.id) == ["a", "b", "c"])
        #expect(list.pinnedListed.map(\.id) == ["b"])
        #expect(list.nextCursor == nil)
        #expect(!list.loading)
        let requests = await transport.requests.filter { $0.route == .list }
        #expect(requests.map { $0.json["cursor"] as? String } == [nil, "c2"])
        #expect(requests.first?.json["key"] as? String == Data(repeating: 1, count: 32).base64EncodedString())
    }

    @Test func aPreviewShowsAChangeUntilItsStoreRefuses() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a", title: "Old")], pinned: []))
        try await list.refresh()
        let undo = list.preview("a", ThreadPatch(title: "New", pinned: true))
        #expect(list.cloudListed.first?.title == "New")
        #expect(list.cloudListed.first?.titleState == .manual)
        #expect(list.pinnedListed.map(\.id) == ["a"])
        undo()
        #expect(list.cloudListed.first?.title == "Old")
        #expect(list.pinnedListed.isEmpty)
    }

    @Test func aRemovalPreviewPutsTheChatBackWhereItWas() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a"), summary("b"), summary("c")], pinned: [summary("b", pinned: true)]))
        try await list.refresh()
        let undo = list.previewRemoval("b")
        #expect(list.cloudListed.map(\.id) == ["a", "c"])
        #expect(list.pinnedListed.isEmpty)
        undo()
        #expect(list.cloudListed.map(\.id) == ["a", "b", "c"])
        #expect(list.pinnedListed.map(\.id) == ["b"])
    }

    @Test func aRunsReportJoinsTheListAndKeepsTheListedFavorite() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a")], pinned: [summary("a", pinned: true)]))
        try await list.refresh()
        // The report comes without the pinned state the list holds.
        list.cloud.reported(summary("a", title: "Titled", pinned: false))
        #expect(list.cloudListed.first?.title == "Titled")
        #expect(list.cloudListed.first?.pinned == true)
        #expect(list.pinnedListed.first?.title == "Titled")
        list.cloud.reported(summary("new", title: "Fresh"))
        #expect(list.cloudListed.map(\.id) == ["new", "a"])
        list.cloud.remove("a")
        #expect(list.cloudListed.map(\.id) == ["new"])
        #expect(list.pinnedListed.isEmpty)
    }

    /// A first page as full as the list reads ahead, so the next waits for
    /// Load More.
    private var fullPage: [ThreadSummary] {
        (0..<ChatList.pageSize).map { summary("p\($0)") }
    }

    @Test func aFailedPageIsReadAgainFromItsCursor() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json(fullPage, pinned: [], next: "c2"))
        try await list.refresh()
        #expect(list.nextCursor == "c2")
        await transport.push(Answers.refusal(503, code: "UPSTREAM_REFUSED", action: "retry"))
        await list.loadMore()?.value
        #expect(list.error != nil)
        #expect(!list.loading)
        #expect(list.cloudListed.count == ChatList.pageSize)
        // The last page's cursor is empty.
        await transport.push(ListPage.json([summary("b")], next: ""))
        await list.retry().value
        #expect(list.error == nil)
        #expect(list.cloudListed.last?.id == "b")
        #expect(list.cloudListed.count == ChatList.pageSize + 1)
        #expect(list.nextCursor == nil)
        let cursors = await transport.requests.filter { $0.route == .list }.map { $0.json["cursor"] as? String }
        #expect(cursors == [nil, "c2", "c2"])
    }

    @Test func aPageLoadsWithTheListMarkedLoading() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json(fullPage, pinned: [], next: "c2"))
        try await list.refresh()
        #expect(!list.loading)
        await transport.push(ListPage.json([summary("b")], next: ""))
        await transport.hold()
        let load = list.loadMore()
        await transport.arrived()
        #expect(list.loading)
        await transport.release()
        await load?.value
        #expect(!list.loading)
        #expect(list.cloudListed.last?.id == "b")
    }
}

private struct NoControlPlane: ControlPlaneTransport {
    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer {
        Issue.record("the control plane was asked for \(path)")
        throw HarnessError(code: HarnessErrorCode.connection, message: "unexpected", action: .stop)
    }
}
