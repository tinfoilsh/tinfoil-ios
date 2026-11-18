import Foundation
import Testing
@testable import TinfoilChat

/// The pages a test's chat service lists, by the cursor that asks for each,
/// and the cursors it was asked for. The first page's cursor is empty.
@MainActor
private final class ScriptedArtifactPages {
    var pages: [String: Result<ArtifactPage, HarnessError>]
    private(set) var asked: [String?] = []

    init(_ pages: [String: Result<ArtifactPage, HarnessError>]) {
        self.pages = pages
    }

    func load(_ cursor: String?) throws -> ArtifactPage {
        asked.append(cursor)
        guard let page = pages[cursor ?? ""] else {
            Issue.record("unscripted page \(cursor ?? "")")
            throw HarnessError(code: HarnessErrorCode.connection, message: "unscripted", action: .stop)
        }
        return try page.get()
    }
}

@Suite("Artifact list")
@MainActor
struct ArtifactListControllerTests {
    private static func artifact(_ thread: String, _ message: String, call: String = "call-1") -> ListedArtifact {
        ListedArtifact(
            threadId: thread,
            threadTitle: "Chat \(thread)",
            messageId: message,
            toolCallId: call,
            title: "",
            sourceType: .named(.html),
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    private static func page(_ artifacts: [ListedArtifact], next: String = "") -> Result<ArtifactPage, HarnessError> {
        .success(ArtifactPage(artifacts: artifacts, nextCursor: next))
    }

    private static let refusal = HarnessError(code: "UPSTREAM_UNAVAILABLE", message: "The chats could not be read.", action: .retry)

    @Test func anArtifactListedAgainOnALaterPageShowsOnce() async throws {
        let first = Self.artifact("thread-1", "msg-1")
        // A model may name calls in different replies alike.
        let sameCall = Self.artifact("thread-1", "msg-2")
        let third = Self.artifact("thread-2", "msg-1")
        let pages = ScriptedArtifactPages([
            "": Self.page([first, sameCall], next: "c1"),
            "c1": Self.page([sameCall, first, third]),
        ])
        let list = ArtifactListController()

        await list.load { try pages.load($0) }.value

        #expect(list.artifacts == [first, sameCall])
        #expect(list.hasMore)
        #expect(!list.isLoading)

        await list.loadMore()?.value

        #expect(list.artifacts == [first, sameCall, third])
        #expect(!list.hasMore)
        #expect(!list.isLoadingMore)
        #expect(list.loadMore() == nil)
        #expect(pages.asked == [nil, "c1"])
    }

    @Test func pagesAreReadUntilOneAddsAnArtifact() async throws {
        let first = Self.artifact("thread-1", "msg-1")
        let second = Self.artifact("thread-2", "msg-1")
        let pages = ScriptedArtifactPages([
            "": Self.page([], next: "c1"),
            "c1": Self.page([first], next: "c2"),
            "c2": Self.page([first], next: "c3"),
            "c3": Self.page([], next: "c4"),
            "c4": Self.page([second]),
        ])
        let list = ArtifactListController()

        await list.load { try pages.load($0) }.value

        #expect(list.artifacts == [first])
        #expect(list.hasMore)
        #expect(pages.asked == [nil, "c1"])

        await list.loadMore()?.value

        #expect(list.artifacts == [first, second])
        #expect(!list.hasMore)
        #expect(pages.asked == [nil, "c1", "c2", "c3", "c4"])
    }

    @Test func aPageThatFailsKeepsWhatIsListedAndIsReadAgain() async throws {
        let first = Self.artifact("thread-1", "msg-1")
        let second = Self.artifact("thread-2", "msg-1")
        let pages = ScriptedArtifactPages([
            "": Self.page([first], next: "c1"),
            "c1": .failure(Self.refusal),
        ])
        let list = ArtifactListController()
        await list.load { try pages.load($0) }.value

        await list.loadMore()?.value

        #expect(list.artifacts == [first])
        #expect(list.error == Self.refusal.localizedDescription)
        #expect(list.hasMore)
        #expect(!list.isLoadingMore)

        pages.pages["c1"] = Self.page([second])
        await list.retry()?.value

        #expect(list.artifacts == [first, second])
        #expect(list.error == nil)
        #expect(!list.hasMore)
        #expect(pages.asked == [nil, "c1", "c1"])
    }

    @Test func aFirstPageThatFailsIsReadAgainFromTheStart() async throws {
        let first = Self.artifact("thread-1", "msg-1")
        let pages = ScriptedArtifactPages(["": .failure(Self.refusal)])
        let list = ArtifactListController()

        await list.load { try pages.load($0) }.value

        #expect(list.artifacts.isEmpty)
        #expect(list.error == Self.refusal.localizedDescription)
        #expect(!list.isLoading)
        #expect(!list.hasMore)

        pages.pages[""] = Self.page([first])
        await list.retry()?.value

        #expect(list.artifacts == [first])
        #expect(list.error == nil)
        #expect(pages.asked == [nil, nil])
    }

    @Test func aCursorThatDoesNotAdvanceEndsTheList() async throws {
        let pages = ScriptedArtifactPages([
            "": Self.page([], next: "c1"),
            "c1": Self.page([], next: "c1"),
        ])
        let list = ArtifactListController()

        await list.load { try pages.load($0) }.value

        #expect(list.artifacts.isEmpty)
        #expect(!list.hasMore)
        #expect(!list.isLoading)
        #expect(pages.asked == [nil, "c1"])
    }

    @Test func listingAgainReplacesWhatWasListed() async throws {
        let first = Self.artifact("thread-1", "msg-1")
        let second = Self.artifact("thread-2", "msg-1")
        let list = ArtifactListController()
        await list.load { _ in ArtifactPage(artifacts: [first], nextCursor: "c1") }.value

        await list.load { _ in ArtifactPage(artifacts: [second], nextCursor: "") }.value

        #expect(list.artifacts == [second])
        #expect(!list.hasMore)
    }

    @Test func leavingTheAccountDropsItsListAndAReplyAlreadyInFlight() async {
        let previous = Self.artifact("prior-account", "m")
        let list = ArtifactListController()
        let (pages, sender) = AsyncStream.makeStream(of: ArtifactPage.self)
        let (requests, started) = AsyncStream.makeStream(of: Bool.self)
        let request = list.load { cursor in
            if cursor == nil { return ArtifactPage(artifacts: [previous], nextCursor: "more") }
            started.yield(true)
            var iterator = pages.makeAsyncIterator()
            guard let page = await iterator.next() else { throw CancellationError() }
            return page
        }
        await request.value
        let continuation = list.loadMore()
        var iterator = requests.makeAsyncIterator()
        _ = await iterator.next()
        list.reset()
        sender.yield(ArtifactPage(artifacts: [previous], nextCursor: "more"))
        sender.finish()
        started.finish()
        await continuation?.value
        #expect(list.artifacts.isEmpty)
        #expect(!list.hasMore)
        #expect(list.retry() == nil)
    }
}
