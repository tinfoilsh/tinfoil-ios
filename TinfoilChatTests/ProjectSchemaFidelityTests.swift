import Foundation
import Testing
@testable import TinfoilChat

@Suite("Project Schema Fidelity Tests")
struct ProjectSchemaFidelityTests {
    @Test("Project color round trips")
    func projectColorRoundTrips() throws {
        let payload = ProjectData(
            name: "Research",
            description: "",
            systemInstructions: "",
            memory: [],
            color: "#0f766e"
        )

        let decoded = try JSONDecoder().decode(
            ProjectData.self,
            from: JSONEncoder().encode(payload)
        )

        #expect(decoded.color == "#0f766e")
    }

    @Test("Legacy project data decodes without color")
    func legacyProjectDataDecodesWithoutColor() throws {
        let data = Data(#"{"name":"Research","description":"","systemInstructions":"","memory":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(ProjectData.self, from: data)

        #expect(decoded.color == nil)
    }

    @Test("Project document preserves original size")
    func projectDocumentPreservesOriginalSize() throws {
        let payload = ProjectDocumentPayload(
            content: "Converted markdown",
            filename: "source.pdf",
            contentType: "application/pdf",
            sizeBytes: 4_096
        )

        let decoded = try JSONDecoder().decode(
            ProjectDocumentPayload.self,
            from: JSONEncoder().encode(payload)
        )

        #expect(decoded.sizeBytes == 4_096)
    }

    @Test("Legacy document size falls back to UTF-8 bytes")
    func legacyDocumentSizeFallsBackToUTF8() throws {
        let data = Data(#"{"content":"caf\u00e9","filename":"notes.txt","contentType":"text/plain"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectDocumentPayload.self, from: data)

        #expect(decoded.sizeBytes == nil)
        #expect(decoded.resolvedSizeBytes == 5)
    }

    @Test("Unrelated project updates preserve color")
    func unrelatedProjectUpdatesPreserveColor() {
        let existing = Project(
            id: "project-1",
            name: "Research",
            description: "Existing",
            systemInstructions: "",
            memory: [],
            color: "#0f766e",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            syncVersion: 1
        )

        let merged = SyncEnclaveProjectStore.mergedProjectData(
            UpdateProjectData(description: "Updated"),
            existing: existing
        )

        #expect(merged.description == "Updated")
        #expect(merged.color == "#0f766e")
    }

    @Test("Bulk delete request uses enclave wire keys")
    func bulkDeleteRequestUsesWireKeys() throws {
        let request = EnclaveDeleteAllProjectsRequest(
            key: "base64-key",
            idempotencyKey: "operation-id"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        )

        #expect(object == [
            "key": "base64-key",
            "idempotency_key": "operation-id"
        ])
    }

    @Test("Bulk delete response decodes deleted count")
    func bulkDeleteResponseDecodesDeletedCount() throws {
        let data = Data(#"{"ok":true,"deleted":3}"#.utf8)
        let response = try JSONDecoder().decode(EnclaveDeleteAllProjectsResponse.self, from: data)

        #expect(response == EnclaveDeleteAllProjectsResponse(ok: true, deleted: 3))
    }
}
