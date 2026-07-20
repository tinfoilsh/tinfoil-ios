import Testing
@testable import TinfoilChat

@MainActor
struct ChatSearchControllerTests {
    @Test
    func requeriesAfterCleanPartialCompletion() async {
        let recorder = ChatSearchServiceTests.Recorder()
        let service = ChatSearchServiceTests.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(
                    results: [],
                    totalIndexed: 0,
                    needsReindex: recorder.queryRequests.count == 1
                )
            },
            searchReindex: { _ in
                EnclaveSearchReindexStatusResponse(
                    jobId: "job-1", status: "completed", indexed: 2, failed: 0,
                    totalIndexed: 2, partial: true, error: nil
                )
            }
        )
        let controller = ChatSearchController(service: service)

        await controller.updateTerm("ducks", userId: "user-1")?.value

        #expect(recorder.queryRequests.count == 2)
        #expect(controller.isIndexing == false)
        #expect(controller.isSearching == false)
    }

    @Test
    func keepsPartialIndexResultsWhenTheRebuildFails() async {
        let recorder = ChatSearchServiceTests.Recorder()
        let service = ChatSearchServiceTests.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(
                    results: [EnclaveSearchQueryResult(id: "a", score: 1)],
                    totalIndexed: 1,
                    needsReindex: true
                )
            },
            searchReindex: { _ in
                EnclaveSearchReindexStatusResponse(
                    jobId: "job-1", status: "failed", indexed: 0, failed: 1,
                    totalIndexed: 1, partial: true, error: "chat could not be indexed"
                )
            },
            loadLocalChat: { chatId, _ in
                ChatSearchServiceTests.makeChat(id: chatId, title: "Pond notes")
            }
        )
        let controller = ChatSearchController(service: service)

        await controller.updateTerm("ducks", userId: "user-1")?.value

        #expect(controller.results.map(\.id) == ["a"])
        #expect(controller.available == true)
        #expect(controller.isIndexing == false)
        #expect(controller.isSearching == false)
        #expect(recorder.queryRequests.count == 1)
    }

    @Test
    func clearsStaleIndexingBannerWhenANewTermStartsSearching() async {
        let recorder = ChatSearchServiceTests.Recorder()
        let service = ChatSearchServiceTests.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(results: [], totalIndexed: 0, needsReindex: true)
            },
            searchReindex: { _ in
                // Keep the rebuild in flight so isIndexing stays raised
                // from the first term's outcome.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return ChatSearchServiceTests.runningStatus()
            }
        )
        let controller = ChatSearchController(service: service)

        controller.updateTerm("duck", userId: "user-1")
        for _ in 0..<100 where !controller.isIndexing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(controller.isIndexing == true)

        controller.updateTerm("ducks", userId: "user-1")

        #expect(controller.isIndexing == false)
        #expect(controller.isSearching == true)
    }

    @Test
    func clearsIndexingAfterFailedRebuild() async {
        let recorder = ChatSearchServiceTests.Recorder()
        let service = ChatSearchServiceTests.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(results: [], totalIndexed: 0, needsReindex: true)
            },
            searchReindex: { _ in
                EnclaveSearchReindexStatusResponse(
                    jobId: "job-1", status: "failed", indexed: 0, failed: 1,
                    totalIndexed: 0, partial: true, error: "chat could not be indexed"
                )
            }
        )
        let controller = ChatSearchController(service: service)

        await controller.updateTerm("ducks", userId: "user-1")?.value

        #expect(controller.isIndexing == false)
        #expect(controller.isSearching == false)
        #expect(controller.available == false)
        #expect(recorder.queryRequests.count == 1)
    }

    @Test
    func fallsBackToLocalSearchAfterTimedOutRebuild() async {
        let recorder = ChatSearchServiceTests.Recorder()
        let service = ChatSearchServiceTests.makeService(
            recorder: recorder,
            searchQuery: { _ in
                EnclaveSearchQueryResponse(results: [], totalIndexed: 0, needsReindex: true)
            },
            searchReindex: { _ in ChatSearchServiceTests.runningStatus() },
            searchReindexStatus: {
                recorder.advance(Constants.SyncEnclave.Search.reindexPollBudgetSeconds)
                return ChatSearchServiceTests.runningStatus()
            }
        )
        let controller = ChatSearchController(service: service)

        await controller.updateTerm("ducks", userId: "user-1")?.value

        #expect(controller.isIndexing == false)
        #expect(controller.isSearching == false)
        #expect(controller.available == false)
    }

    @Test
    func clearsIndexingWhenARefreshThrows() async {
        let recorder = ChatSearchServiceTests.Recorder()
        let service = ChatSearchServiceTests.makeService(
            recorder: recorder,
            searchQuery: { _ in
                if recorder.queryRequests.count == 1 {
                    return EnclaveSearchQueryResponse(
                        results: [],
                        totalIndexed: 0,
                        needsReindex: true
                    )
                }
                throw SyncEnclaveError(message: "network down")
            }
        )
        let controller = ChatSearchController(service: service)

        await controller.updateTerm("ducks", userId: "user-1")?.value

        #expect(controller.isIndexing == false)
        #expect(controller.isSearching == false)
        #expect(controller.available == false)
        #expect(recorder.queryRequests.count == 2)
    }

    @Test
    func searchResultFilterKeepsProjectChatsButDropsTemporaryAndEncrypted() {
        let root = ChatSearchServiceTests.makeChat(id: "root", title: "Root")
        var project = ChatSearchServiceTests.makeChat(id: "project", title: "Project")
        project.projectId = "project-1"
        var temporary = ChatSearchServiceTests.makeChat(id: "temp", title: "Temp")
        temporary.isTemporary = true
        var encrypted = ChatSearchServiceTests.makeChat(id: "encrypted", title: "Encrypted")
        encrypted.decryptionFailed = true

        let visible = [root, project, temporary, encrypted]
            .filter(isSearchResultSidebarChat)
            .map(\.id)
        #expect(visible == ["root", "project"])

        // The root chat list itself still excludes project chats.
        #expect([root, project].filter(isRootSidebarChat).map(\.id) == ["root"])
    }

    @Test
    func sidebarSearchIsOnlyEnabledForCloudChats() {
        #expect(
            isSidebarChatSearchEnabled(
                isAuthenticated: true,
                isCloudSyncEnabled: true,
                activeTab: .cloud
            )
        )
        #expect(
            !isSidebarChatSearchEnabled(
                isAuthenticated: true,
                isCloudSyncEnabled: true,
                activeTab: .local
            )
        )
    }
}
