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
        #expect(recorder.queryRequests.count == 1)
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
        #expect(recorder.queryRequests.count == 2)
    }

    @Test
    func rootSidebarFilterExcludesProjectSearchResults() {
        let root = ChatSearchServiceTests.makeChat(id: "root", title: "Root")
        var project = ChatSearchServiceTests.makeChat(id: "project", title: "Project")
        project.projectId = "project-1"

        #expect([root, project].filter(isRootSidebarChat).map(\.id) == ["root"])
    }
}
