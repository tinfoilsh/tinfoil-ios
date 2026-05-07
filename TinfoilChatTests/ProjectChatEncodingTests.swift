import Foundation
import Testing
@testable import TinfoilChat

struct ProjectChatEncodingTests {
    @Test @MainActor
    func chatCreatePreservesProjectId() {
        let chat = Chat.create(
            id: "chat-1",
            modelType: Self.testModel,
            projectId: "project-1"
        )

        #expect(chat.projectId == "project-1")
        #expect(chat.isLocalOnly == false)
    }

    @Test @MainActor
    func storedChatRoundTripsProjectId() throws {
        let chat = Chat.create(
            id: "chat-1",
            modelType: Self.testModel,
            projectId: "project-1"
        )
        let stored = StoredChat(from: chat)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredChat.self, from: data)

        #expect(decoded.projectId == "project-1")
    }

    private static let testModel = ModelType(
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
}
