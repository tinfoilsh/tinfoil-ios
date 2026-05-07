import Foundation
import Testing
@testable import TinfoilChat

struct ProjectContextBuilderTests {
    @Test func buildsWebappCompatibleProjectContext() {
        let project = Project(
            id: "project-1",
            name: "Private Penguin",
            description: "Launch notes",
            systemInstructions: "Prefer concise answers.",
            memory: [
                MemoryFact(
                    id: "fact-1",
                    fact: "User likes short updates.",
                    date: "2026-05-07T00:00:00.000Z",
                    category: "preference",
                    confidence: 1
                )
            ],
            createdAt: "2026-05-07T00:00:00.000Z",
            updatedAt: "2026-05-07T00:00:00.000Z",
            syncVersion: 1
        )
        let documents = [
            ProjectDocument(
                id: "doc-1",
                projectId: "project-1",
                filename: "brief.md",
                contentType: "text/markdown",
                sizeBytes: 12,
                syncVersion: 1,
                createdAt: "2026-05-07T00:00:00.000Z",
                updatedAt: "2026-05-07T00:00:00.000Z",
                content: "Important context"
            )
        ]

        let context = ProjectContextBuilder.build(project: project, documents: documents)

        #expect(context.contains("## Project: Private Penguin"))
        #expect(context.contains("Launch notes"))
        #expect(context.contains("### Instructions\nPrefer concise answers."))
        #expect(context.contains("--- brief.md ---\nImportant context"))
        #expect(!context.contains("User likes short updates."))
    }

    @Test func wrapsSystemPromptWithProjectContext() {
        let project = Project(
            id: "project-1",
            name: "Private Penguin",
            description: "",
            systemInstructions: "",
            memory: [],
            createdAt: "2026-05-07T00:00:00.000Z",
            updatedAt: "2026-05-07T00:00:00.000Z",
            syncVersion: 1
        )

        let prompt = ProjectContextBuilder.applyProjectContext(
            to: "Base prompt",
            project: project,
            documents: []
        )

        #expect(prompt == "Base prompt\n\n<project_context>\n## Project: Private Penguin\n\n</project_context>")
    }
}
