import Foundation
import Testing
@testable import TinfoilChat

struct AtomicProjectDeletionTests {
    @Test func requestEncodesAndResponseDecodes() throws {
        let request = EnclaveDeleteAllProjectsRequest(
            key: "base64-key",
            idempotencyKey: "idempotency-key"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        )

        #expect(object == [
            "key": "base64-key",
            "idempotency_key": "idempotency-key",
        ])

        let response = try JSONDecoder().decode(
            EnclaveDeleteAllProjectsResponse.self,
            from: Data(#"{"ok":true,"deleted":7}"#.utf8)
        )
        #expect(response.ok)
        #expect(response.deleted == 7)
    }

    @Test func storeReturnsDeletedCountForSuccessfulResponse() async throws {
        let store = SyncEnclaveProjectStore(
            deleteAllProjectsOperation: { request in
                #expect(request.key == "base64-key")
                #expect(!request.idempotencyKey.isEmpty)
                return EnclaveDeleteAllProjectsResponse(ok: true, deleted: 4)
            },
            requirePrimaryKeyB64: { "base64-key" }
        )

        #expect(try await store.deleteAllProjects() == 4)
    }

    @Test func storeRejectsUnsuccessfulResponse() async {
        let store = SyncEnclaveProjectStore(
            deleteAllProjectsOperation: { _ in
                EnclaveDeleteAllProjectsResponse(ok: false, deleted: 4)
            },
            requirePrimaryKeyB64: { "base64-key" }
        )

        await #expect(throws: CloudStorageError.self) {
            _ = try await store.deleteAllProjects()
        }
    }

    @Test func bulkDeletionInvalidatesStaleProjectLoads() {
        var listGeneration = 3
        var projectGeneration = 8
        let staleListGeneration = listGeneration
        let staleProjectGeneration = projectGeneration

        ProjectLoadGenerationFence.invalidate(
            listGeneration: &listGeneration,
            projectGeneration: &projectGeneration
        )

        #expect(listGeneration == staleListGeneration + 1)
        #expect(projectGeneration == staleProjectGeneration + 1)
        #expect(!ProjectLoadGenerationFence.isCurrent(
            staleListGeneration,
            currentGeneration: listGeneration
        ))
        #expect(!ProjectLoadGenerationFence.isCurrent(
            staleProjectGeneration,
            currentGeneration: projectGeneration
        ))
    }
}
