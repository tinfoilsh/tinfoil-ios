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
        pullKeys: @escaping () -> [EnclavePullKey]? = { [EnclavePullKey(key: "primary-b64")] },
        reindexKeys: @escaping () -> [EnclavePullKey] = { [EnclavePullKey(key: "primary-b64")] },
        sleep: @escaping (TimeInterval) async throws -> Void = { _ in }
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
            reindexKeys: reindexKeys,
            sleep: sleep,
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
    func allowsQueriesWhileLegacyKeysRemainAvailableForReindex() async throws {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(results: [], totalIndexed: 0, needsReindex: true)
            },
            reindexKeys: {
                [
                    EnclavePullKey(key: "primary-b64"),
                    EnclavePullKey(key: "legacy-b64"),
                ]
            }
        )
        let outcome = try await service.searchSyncedChats(query: "ducks")
        #expect(outcome.available)
        #expect(outcome.indexing)
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .completed)
        #expect(recorder.queryRequests.map(\.key) == ["primary-b64"])
        #expect(recorder.reindexRequests[0].keys.map(\.key) == ["primary-b64", "legacy-b64"])
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
        let service = Self.makeService(recorder: recorder, reindexKeys: { [] })
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .skipped)
        #expect(recorder.reindexRequests.isEmpty)
    }

    @Test
    func treatsAnIdleStatusPollAsACompletedRebuild() async {
        // A finished job is only retained briefly server-side; a poll
        // that resumes after suspension can land on "idle". That must
        // not start the failure cooldown.
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchReindex: { _ in Self.runningStatus() },
            searchReindexStatus: {
                EnclaveSearchReindexStatusResponse(
                    jobId: nil, status: "idle", indexed: 0, failed: 0,
                    totalIndexed: 4, partial: false, error: nil
                )
            }
        )
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .completed)

        let rekick = await service.ensureSearchIndex().value
        #expect(rekick == .completed)
        #expect(recorder.reindexRequests.count == 2)
    }

    @Test
    func treatsAnIdleKickoffResponseAsAFailureAndStartsTheCooldown() async {
        // Kickoff always materializes a job, so an "idle" answer means
        // none was created; success here would clear the cooldown and
        // let callers loop.
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchReindex: { _ in
            EnclaveSearchReindexStatusResponse(
                jobId: nil, status: "idle", indexed: 0, failed: 0,
                totalIndexed: 0, partial: false, error: nil
            )
        })
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .failed)

        let rekick = await service.ensureSearchIndex().value
        #expect(rekick == .skipped)
        #expect(recorder.reindexRequests.count == 1)
    }

    @Test
    func treatsAnUnknownTerminalStatusAsFailure() async {
        let recorder = Recorder()
        let service = Self.makeService(recorder: recorder, searchReindex: { _ in
            EnclaveSearchReindexStatusResponse(
                jobId: "job-1", status: "paused", indexed: 0, failed: 0,
                totalIndexed: 0, partial: false, error: nil
            )
        })
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .failed)

        let rekick = await service.ensureSearchIndex().value
        #expect(rekick == .skipped)
        #expect(recorder.reindexRequests.count == 1)
    }

    @Test
    func treatsCleanPartialCompletionAsResumableWithoutCooldown() async {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchReindex: { _ in Self.runningStatus() },
            searchReindexStatus: {
                EnclaveSearchReindexStatusResponse(
                    jobId: "job-1", status: "completed", indexed: 4, failed: 0,
                    totalIndexed: 4, partial: true, error: nil
                )
            }
        )
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .partial)

        let resumed = await service.ensureSearchIndex().value
        #expect(resumed == .partial)
        #expect(recorder.reindexRequests.count == 2)
    }

    @Test
    func treatsPositiveFailureCountAsFailureEvenWhenStatusIsCompleted() async {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchReindex: { _ in Self.runningStatus() },
            searchReindexStatus: {
                EnclaveSearchReindexStatusResponse(
                    jobId: "job-1", status: "completed", indexed: 3, failed: 1,
                    totalIndexed: 3, partial: true, error: nil
                )
            }
        )
        let settled = await service.ensureSearchIndex().value
        #expect(settled == .failed)

        let rekick = await service.ensureSearchIndex().value
        #expect(rekick == .skipped)
        #expect(recorder.reindexRequests.count == 1)
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

    @Test
    func pollBudgetOutlivesTheServerJobBudget() async {
        let recorder = Recorder()
        let service = Self.makeService(
            recorder: recorder,
            searchReindex: { _ in Self.runningStatus() },
            searchReindexStatus: {
                if recorder.statusPolls == 1 {
                    recorder.advance(
                        Constants.SyncEnclave.Search.reindexServerBudgetSeconds
                            + Constants.SyncEnclave.Search.reindexPollIntervalSeconds
                    )
                    return Self.runningStatus()
                }
                return Self.completedStatus()
            }
        )
        let settled = await service.ensureSearchIndex().value
        #expect(
            Constants.SyncEnclave.Search.reindexPollBudgetSeconds
                > Constants.SyncEnclave.Search.reindexServerBudgetSeconds
        )
        #expect(settled == .completed)
        #expect(recorder.statusPolls == 2)
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
            pullKeys: { [EnclavePullKey(key: "pull-key")] },
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
        #expect(recorder.pullRequests[0].keys.map(\.key) == ["pull-key"])
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

    // MARK: - Pulled chat decoding

    @Test
    func pulledChatUsesAuthoritativeETagAndProjectAssignment() throws {
        let item = Self.makePullItem(
            etag: "12",
            projectIdSet: true,
            projectId: "project-new",
            plaintextProjectId: "project-old",
            plaintextSyncVersion: 3
        )

        let stored = try #require(decodeSearchPulledChat(item))
        #expect(stored.syncVersion == 12)
        #expect(stored.projectId == "project-new")
        #expect(stored.formatVersion == Constants.SyncEnclave.plaintextChatFormatVersion)
    }

    @Test
    func pulledChatClearsAuthoritativeRootProject() throws {
        let item = Self.makePullItem(
            etag: "12",
            projectIdSet: true,
            projectId: nil,
            plaintextProjectId: "project-old"
        )

        let stored = try #require(decodeSearchPulledChat(item))
        #expect(stored.projectId == nil)
    }

    @Test
    func pulledChatPreservesProjectForOlderEnclaveResponse() throws {
        let item = Self.makePullItem(
            etag: "12",
            projectIdSet: nil,
            projectId: nil,
            plaintextProjectId: "project-old"
        )

        let stored = try #require(decodeSearchPulledChat(item))
        #expect(stored.projectId == "project-old")
    }

    @Test
    func pulledChatRequiresAPositiveNumericETag() {
        let invalidETags: [String?] = [nil, "", "not-a-number", "0", "-1"]
        for etag in invalidETags {
            let item = Self.makePullItem(etag: etag)
            #expect(decodeSearchPulledChat(item) == nil)
        }
    }

    private static func makePullItem(
        etag: String?,
        projectIdSet: Bool? = nil,
        projectId: String? = nil,
        plaintextProjectId: String? = nil,
        plaintextSyncVersion: Int = 1
    ) -> EnclavePullItem {
        var chat = makeChat(id: "remote", title: "Remote")
        chat.projectId = plaintextProjectId
        let plaintext = try! JSONEncoder().encode(
            StoredChat(from: chat, syncVersion: plaintextSyncVersion)
        ).base64EncodedString()
        var json: [String: Any] = [
            "id": chat.id,
            "ok": true,
            "plaintext": plaintext,
        ]
        if let etag {
            json["etag"] = etag
        }
        if let projectIdSet {
            json["project_id_set"] = projectIdSet
        }
        if let projectId {
            json["project_id"] = projectId
        }
        return EnclavePullResponse(json: ["items": [json]]).items[0]
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
