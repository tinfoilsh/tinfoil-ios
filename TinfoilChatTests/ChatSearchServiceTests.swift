import Foundation
import Testing
@testable import TinfoilChat

/// Mirrors the webapp's `tests/services/cloud/chat-search.test.ts`.
@MainActor
struct ChatSearchServiceTests {

    // MARK: - Harness

    /// Mutable capture box shared between stub closures and assertions.
    /// Deliberately not actor-isolated so the service's nonisolated
    /// dependency closures can record calls synchronously; every test
    /// runs single-threaded on the main actor.
    final class Recorder {
        var queryRequests: [EnclaveSearchQueryRequest] = []
        var reindexRequests: [EnclaveSearchReindexRequest] = []
        var statusPolls = 0
        var pullRequests: [EnclavePullRequest] = []
        var now = Date(timeIntervalSince1970: 1_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    nonisolated static func runningStatus() -> EnclaveSearchReindexStatusResponse {
        EnclaveSearchReindexStatusResponse(
            jobId: "job-1", status: "running", indexed: 0, failed: 0,
            totalIndexed: 0, partial: false, error: nil
        )
    }

    nonisolated static func completedStatus() -> EnclaveSearchReindexStatusResponse {
        EnclaveSearchReindexStatusResponse(
            jobId: "job-1", status: "completed", indexed: 4, failed: 0,
            totalIndexed: 4, partial: false, error: nil
        )
    }

    static func makeService(
        recorder: Recorder,
        searchQuery: @escaping (EnclaveSearchQueryRequest) async throws -> EnclaveSearchQueryResponse = { _ in
            EnclaveSearchQueryResponse(results: [], totalIndexed: 0, needsReindex: false)
        },
        searchReindex: @escaping (EnclaveSearchReindexRequest) async throws -> EnclaveSearchReindexStatusResponse = { _ in
            Self.completedStatus()
        },
        searchReindexStatus: @escaping () async throws -> EnclaveSearchReindexStatusResponse = {
            Self.completedStatus()
        },
        pull: @escaping (EnclavePullRequest) async throws -> EnclavePullResponse = { _ in
            throw SyncEnclaveError(message: "pull not stubbed")
        },
        loadLocalChat: @escaping (String, String) async -> Chat? = { _, _ in nil },
        decodeRemoteChat: @escaping (EnclavePullItem) async -> Chat? = { _ in nil },
        primaryKeyB64: @escaping () -> String? = { "primary-b64" },
        pullKeys: @escaping () -> [EnclavePullKey]? = { [EnclavePullKey(key: "primary-b64")] }
    ) -> ChatSearchService {
        ChatSearchService(dependencies: ChatSearchService.Dependencies(
            searchQuery: { request in
                recorder.queryRequests.append(request)
                return try await searchQuery(request)
            },
            searchReindex: { request in
                recorder.reindexRequests.append(request)
                return try await searchReindex(request)
            },
            searchReindexStatus: {
                recorder.statusPolls += 1
                return try await searchReindexStatus()
            },
            pull: { request in
                recorder.pullRequests.append(request)
                return try await pull(request)
            },
            loadLocalChat: loadLocalChat,
            decodeRemoteChat: decodeRemoteChat,
            primaryKeyB64: primaryKeyB64,
            pullKeys: pullKeys,
            sleep: { _ in },
            now: { recorder.now }
        ))
    }

    nonisolated static let testModel = ModelType(
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
            reasoningConfig: nil
        )
    )

    nonisolated static func makeChat(id: String, title: String) -> Chat {
        Chat(id: id, title: title, modelType: testModel)
    }

    // MARK: - searchSyncedChats

    @Test
    func reportsUnavailableWhenNoPrimaryKeyIsLoaded() async throws {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, primaryKeyB64: { nil })
        let outcome = try await service.searchSyncedChats(query: "ducks")
        #expect(outcome == .unavailable)
        #expect(recorder.queryRequests.isEmpty)
    }

    @Test
    func mapsA503FromTheEnclaveToUnavailableInsteadOfThrowing() async throws {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchQuery: { _ in
            throw SyncEnclaveError(message: "search backend not configured", status: 503)
        })
        let outcome = try await service.searchSyncedChats(query: "ducks")
        #expect(outcome.available == false)
        #expect(outcome.results.isEmpty)
    }

    @Test
    func rethrowsTransientErrorsSoCallersCanDistinguishThem() async {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchQuery: { _ in
            throw SyncEnclaveError(message: "embedding service failed", status: 502)
        })
        await #expect(throws: SyncEnclaveError.self) {
            try await service.searchSyncedChats(query: "ducks")
        }
    }

    @Test
    func returnsRankedResultsAndPassesKeyAndLimitToTheEnclave() async throws {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchQuery: { _ in
            EnclaveSearchQueryResponse(
                results: [
                    EnclaveSearchQueryResult(id: "b", score: 2),
                    EnclaveSearchQueryResult(id: "a", score: 1),
                ],
                totalIndexed: 9,
                needsReindex: false
            )
        })
        let outcome = try await service.searchSyncedChats(query: "duck pond", limit: 7)
        #expect(outcome.results.map(\.id) == ["b", "a"])
        #expect(outcome.totalIndexed == 9)
        #expect(outcome.indexing == false)
        #expect(outcome.available == true)
        #expect(recorder.queryRequests.count == 1)
        #expect(recorder.queryRequests[0].key == "primary-b64")
        #expect(recorder.queryRequests[0].query == "duck pond")
        #expect(recorder.queryRequests[0].limit == 7)
        #expect(recorder.reindexRequests.isEmpty)
    }

    // MARK: - ensureSearchIndex

    @Test
    func kicksOneSharedReindexWhenQueriesReportNeedsReindexAndPollsItToCompletion() async throws {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(results: [], totalIndexed: 0, needsReindex: true)
            },
            searchReindex: { _ in Self.runningStatus() },
            searchReindexStatus: {
                recorder.statusPolls < 2 ? Self.runningStatus() : Self.completedStatus()
            }
        )

        let first = try await service.searchSyncedChats(query: "ducks")
        let second = try await service.searchSyncedChats(query: "taxes")
        #expect(first.indexing == true)
        #expect(second.indexing == true)

        let settled = await service.ensureSearchIndex().value
        #expect(settled == .completed)
        #expect(recorder.reindexRequests.count == 1)
        #expect(recorder.reindexRequests[0].keys.map(\.key) == ["primary-b64"])
        #expect(recorder.statusPolls == 2)
    }

    @Test
    func doesNotPollWhenTheKickoffAlreadyReportsATerminalStatus() async {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder)
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .completed)
        #expect(recorder.statusPolls == 0)
    }

    @Test
    func skipsTheKickWhenNoKeysAreLoaded() async {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, pullKeys: { nil })
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .skipped)
        #expect(recorder.reindexRequests.isEmpty)
    }

    @Test
    func putsKicksOnCooldownAfterAFailedRunInsteadOfLoopingRebuilds() async {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchReindex: { _ in
            EnclaveSearchReindexStatusResponse(
                jobId: "job-1", status: "failed", indexed: 0, failed: 1,
                totalIndexed: 0, partial: false, error: "embedding service failed"
            )
        })

        let first = await service.ensureSearchIndex().value
        #expect(first == .failed)
        #expect(recorder.reindexRequests.count == 1)

        let second = await service.ensureSearchIndex().value
        #expect(second == .skipped)
        #expect(recorder.reindexRequests.count == 1)

        recorder.advance(Constants.SyncEnclave.Search.reindexFailureCooldownSeconds)
        let third = await service.ensureSearchIndex().value
        #expect(third == .failed)
        #expect(recorder.reindexRequests.count == 2)
    }

    @Test
    func settlesAsFailedWhenTheRebuildKickThrows() async {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchReindex: { _ in
            throw SyncEnclaveError(message: "network down")
        })
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .failed)
    }

    @Test
    func timesOutWhenTheJobOutlivesThePollBudget() async {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchReindex: { _ in Self.runningStatus() },
            searchReindexStatus: {
                // Each poll burns poll-interval wall time on the fake clock.
                recorder.advance(Constants.SyncEnclave.Search.reindexPollBudgetSeconds / 2)
                return Self.runningStatus()
            }
        )
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .timeout)
    }

    // MARK: - resolveSearchResultChats

    @Test
    func resolvesResultsLocallyFirstPullsTheRestAndPreservesRanking() async {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            pull: { _ in
                EnclavePullResponse(json: [
                    "items": [
                        ["id": "b", "ok": true, "plaintext": "ignored-by-stub"],
                        ["id": "c", "ok": false, "code": "NOT_FOUND"],
                    ],
                ])
            },
            loadLocalChat: { chatId, userId in
                #expect(userId == "user-1")
                return chatId == "a" ? Self.makeChat(id: "a", title: "Local pond notes") : nil
            },
            decodeRemoteChat: { item in
                item.id == "b" ? Self.makeChat(id: "b", title: "Remote tax chat") : nil
            }
        )

        let chats = await service.resolveSearchResultChats(
            [
                EnclaveSearchQueryResult(id: "b", score: 3),
                EnclaveSearchQueryResult(id: "a", score: 2),
                EnclaveSearchQueryResult(id: "c", score: 1),
            ],
            userId: "user-1"
        )

        #expect(chats.map(\.id) == ["b", "a"])
        #expect(chats[0].title == "Remote tax chat")
        #expect(chats[1].title == "Local pond notes")
        #expect(recorder.pullRequests.count == 1)
        #expect(recorder.pullRequests[0].ids == ["b", "c"])
        #expect(recorder.pullRequests[0].scope == .chat)
    }

    @Test
    func skipsThePullEntirelyWhenEveryResultResolvesLocally() async {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            loadLocalChat: { chatId, _ in Self.makeChat(id: chatId, title: "Local") }
        )
        let chats = await service.resolveSearchResultChats(
            [EnclaveSearchQueryResult(id: "a", score: 1)],
            userId: "user-1"
        )
        #expect(chats.count == 1)
        #expect(recorder.pullRequests.isEmpty)
    }

    @Test
    func dropsUndecryptablePlaceholdersFromResults() async {
        let recorder = Recorder()
        var placeholder = Self.makeChat(id: "a", title: "Encrypted")
        placeholder.decryptionFailed = true
        let service = Self.makeService(
            recorder: recorder,
            loadLocalChat: { _, _ in placeholder }
        )
        let chats = await service.resolveSearchResultChats(
            [EnclaveSearchQueryResult(id: "a", score: 1)],
            userId: "user-1"
        )
        #expect(chats.isEmpty)
    }
}

// MARK: - Decodable fixtures

private extension EnclavePullResponse {
    /// Build a pull response through its Decodable path (the struct has
    /// no memberwise initializer).
    init(json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        self = try! JSONDecoder().decode(EnclavePullResponse.self, from: data)
    }
}
