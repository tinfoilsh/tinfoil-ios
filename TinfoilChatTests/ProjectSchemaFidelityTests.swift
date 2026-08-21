import Foundation
import Testing
@testable import TinfoilChat

struct ProjectSchemaFidelityTests {
    @Test func projectSchemasRoundTripColor() throws {
        let project = Project(
            id: "project-1",
            name: "Project",
            color: "#1A2B3C",
            description: "Description",
            systemInstructions: "Instructions",
            memory: [],
            createdAt: "2026-08-20T00:00:00.000Z",
            updatedAt: "2026-08-20T00:00:00.000Z",
            syncVersion: 1
        )
        let projectData = ProjectData(
            name: project.name,
            color: project.color,
            description: project.description,
            systemInstructions: project.systemInstructions,
            memory: project.memory
        )
        let createData = CreateProjectData(name: project.name, color: project.color)
        let updateData = UpdateProjectData(color: project.color)

        #expect(try roundTrip(project).color == "#1A2B3C")
        #expect(try roundTrip(projectData).color == "#1A2B3C")
        #expect(try roundTrip(createData).color == "#1A2B3C")
        #expect(try roundTrip(updateData).color == "#1A2B3C")
        #expect(ProjectData(createData: createData).color == "#1A2B3C")
    }

    @Test func unrelatedProjectUpdatePreservesColor() {
        let existing = Project(
            id: "project-1",
            name: "Project",
            color: "blue",
            description: "Old description",
            systemInstructions: "Instructions",
            memory: [],
            createdAt: "2026-08-20T00:00:00.000Z",
            updatedAt: "2026-08-20T00:00:00.000Z",
            syncVersion: 1
        )

        let merged = ProjectData(
            updateData: UpdateProjectData(description: "New description"),
            existing: existing
        )

        #expect(merged.color == "blue")
        #expect(merged.description == "New description")
    }

    @Test func documentPayloadRoundTripsOriginalSize() throws {
        let payload = ProjectDocumentPayload(
            content: "converted markdown",
            filename: "source.pdf",
            contentType: "application/pdf",
            sizeBytes: 42_000
        )

        let decoded = try roundTrip(payload)

        #expect(decoded.sizeBytes == 42_000)
        #expect(decoded.resolvedSizeBytes == 42_000)
    }

    @Test func legacyDocumentPayloadFallsBackToUTF8Size() throws {
        let data = Data(
            #"{"content":"café","filename":"legacy.txt","contentType":"text/plain"}"#.utf8
        )

        let payload = try JSONDecoder().decode(ProjectDocumentPayload.self, from: data)

        #expect(payload.sizeBytes == nil)
        #expect(payload.resolvedSizeBytes == "café".utf8.count)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
