import Foundation
import Testing
@testable import TinfoilChat

private func summary(_ id: String, title: String = "Chat", pinned: Bool = false, projectId: String? = nil, at: String = "2026-01-01T00:00:00Z") -> ThreadSummary {
    ThreadSummary(
        id: id, title: title, titleState: .named(.generated), createdAt: at, updatedAt: at, activityAt: at, projectId: projectId,
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
        let (list, transport, _) = await makeListAndAccount()
        return (list, transport)
    }

    private func makeListAndAccount() async -> (ChatList, ScriptedTransport, HarnessAccount) {
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
        return (list, transport, account)
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

    @Test func aChangeTheHarnessReportsListsTheStoredChatsAgain() async throws {
        let (list, transport, account) = await makeListAndAccount()
        await transport.push(ListPage.json([summary("a")], pinned: []))
        try await list.refresh()
        await transport.push(Answers.json(["chats": "c2", "profile": "p2", "projects": "j2"]))
        await transport.push(Answers.json([:]))
        await transport.push(ListPage.json([summary("b"), summary("a")], pinned: []))
        await account.checkChanges()
        var waited = 0
        while list.cloudListed.count < 2, waited < 100 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(list.cloudListed.map(\.id) == ["b", "a"])
        let routes = await transport.requests.map(\.route)
        #expect(Array(routes.suffix(3)) == [.changes, .profileGet, .list])
    }

    @Test func aPreviewShowsAChangeUntilItsStoreRefuses() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a", title: "Old")], pinned: []))
        try await list.refresh()
        let undo = list.preview("a", ThreadPatch(title: "New", pinned: true))
        #expect(list.cloudListed.first?.title == "New")
        #expect(list.cloudListed.first?.titleState.value1 == .manual)
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

    @Test func onlyAPageAfterThoseListedShowsAsLoadingMore() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json(fullPage, pinned: [], next: "c2"))
        await transport.hold()
        let reload = list.reload()
        await transport.arrived()
        #expect(list.loading)
        #expect(!list.loadingMore)
        await transport.release()
        await reload.value
        await transport.push(ListPage.json([summary("b")], next: ""))
        await transport.hold()
        let load = list.loadMore()
        await transport.arrived()
        #expect(list.loadingMore)
        await transport.release()
        await load?.value
        #expect(!list.loadingMore)
        #expect(list.cloudListed.last?.id == "b")
    }

    @Test func aProjectsChatsAreListedApartPageByPage() async throws {
        let (list, transport) = await makeList()
        let firstPage = (0..<ChatList.pageSize).map { summary("p\($0)", projectId: "p") }
        await transport.push(ListPage.json(firstPage, pinned: [], next: "c2"))
        list.listProject("p")
        let project = try #require(list.project)
        var waited = 0
        while project.cloudListed.isEmpty, waited < 100 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(project.cloudListed == firstPage)
        await transport.push(ListPage.json([summary("b", projectId: "p")], next: ""))
        await project.loadMore()?.value
        #expect(project.cloudListed == firstPage + [summary("b", projectId: "p")])
        let requests = await transport.requests.filter { $0.route == .list }
        #expect(requests.map { $0.json["projectId"] as? String } == ["p", "p"])
        #expect(requests.map { $0.json["cursor"] as? String } == [nil, "c2"])
        list.listProject(nil)
        #expect(list.project == nil)
    }

    @Test func aProjectsListShowsTheChangesMadeThroughTheList() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a", projectId: "p"), summary("b", projectId: "p"), summary("r")], pinned: []))
        try await list.refresh()
        await transport.push(ListPage.json([summary("a", projectId: "p"), summary("b", projectId: "p")], pinned: []))
        list.listProject("p")
        let project = try #require(list.project)
        var waited = 0
        while project.cloudListed.isEmpty, waited < 100 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let undoTitle = list.preview("a", ThreadPatch(title: "Renamed"))
        #expect(project.cloudListed.first { $0.id == "a" }?.title == "Renamed")
        undoTitle()
        #expect(project.cloudListed.first { $0.id == "a" }?.title == "Chat")
        let undoRemoval = list.previewRemoval("b")
        #expect(project.cloudListed.map(\.id) == ["a"])
        undoRemoval()
        #expect(project.cloudListed.map(\.id) == ["a", "b"])
        // A chat moved into the project joins its list, and one moved out
        // leaves it.
        list.cloud.replace(summary("r", projectId: "p"))
        list.cloud.replace(summary("a"))
        #expect(project.cloudListed.map(\.id) == ["r", "b"])
        list.cloud.remove("b")
        #expect(project.cloudListed.map(\.id) == ["r"])
    }

    @Test func theProjectsListedLastAreKeptSealedUntilTheListIsCleared() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatListCache(directory: directory)
        #expect(await cache.readProjects() == nil)
        let projects = [Project(Components.Schemas.Project(id: "p1", name: "Taxes", description: "Receipts", systemInstructions: "Be brief", color: "blue"))]
        await cache.writeProjects(projects)
        #expect(await cache.readProjects() == projects)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(!String(decoding: try Data(contentsOf: try #require(files.first)), as: UTF8.self).contains("Taxes"))
        cache.clear()
        #expect(await cache.readProjects() == nil)
    }

    @Test func anEditDuringAReloadKeepsTheEditAndEndsTheLoad() async throws {
        let (list, transport) = await makeList()
        await transport.push(ListPage.json([summary("a")], pinned: []))
        try await list.refresh()
        await transport.push(ListPage.json([summary("a")], pinned: []))
        await transport.hold()
        let load = list.reload()
        await transport.arrived()
        #expect(list.loading)
        // The run reports a chat while the page is in flight: the page is
        // older than the report, and does not replace it.
        list.cloud.reported(summary("fresh", title: "Fresh"))
        await transport.release()
        await load.value
        #expect(!list.loading)
        #expect(list.cloudListed.map(\.id) == ["fresh", "a"])
    }
}

private struct NoControlPlane: ControlPlaneTransport {
    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer {
        Issue.record("the control plane was asked for \(path)")
        throw HarnessError(code: HarnessErrorCode.connection, message: "unexpected", action: .stop)
    }
}
