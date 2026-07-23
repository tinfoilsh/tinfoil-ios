import Foundation
import Testing
@testable import TinfoilChat

private let testModel = ModelType(
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
        toolCalling: nil,
        attributes: nil,
        reasoningConfig: nil
    )
)

struct ProjectChatEncodingTests {
    @Test @MainActor
    func chatCreatePreservesProjectId() {
        let chat = Chat.create(
            id: "chat-1",
            modelType: testModel,
            projectId: "project-1"
        )

        #expect(chat.projectId == "project-1")
        #expect(chat.isLocalOnly == false)
    }

    @Test @MainActor
    func storedChatRoundTripsProjectId() throws {
        let chat = Chat.create(
            id: "chat-1",
            modelType: testModel,
            projectId: "project-1"
        )
        let stored = StoredChat(from: chat)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredChat.self, from: data)

        #expect(decoded.projectId == "project-1")
    }
}

struct WebSearchChatPreferenceTests {
    @Test
    func chatDefaultsWebSearchToOn() {
        let chat = Chat(modelType: testModel)

        #expect(chat.webSearchEnabled)
    }

    @Test
    func chatRoundTripsDisabledWebSearch() throws {
        let chat = Chat(modelType: testModel, webSearchEnabled: false)
        let data = try JSONEncoder().encode(chat)
        let decoded = try JSONDecoder().decode(Chat.self, from: data)

        #expect(decoded.webSearchEnabled == false)
    }

    @Test
    func legacyChatDefaultsWebSearchToOn() throws {
        let chat = Chat(modelType: testModel, webSearchEnabled: false)
        let data = try JSONEncoder().encode(chat)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "webSearchEnabled")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Chat.self, from: legacyData)

        #expect(decoded.webSearchEnabled)
    }

    @Test @MainActor
    func storedChatRoundTripsDisabledWebSearch() throws {
        let chat = Chat(modelType: testModel, webSearchEnabled: false)
        let data = try JSONEncoder().encode(StoredChat(from: chat))
        let stored = try JSONDecoder().decode(StoredChat.self, from: data)
        let decoded = try #require(stored.toChat())

        #expect(stored.webSearchEnabled == false)
        #expect(decoded.webSearchEnabled == false)
    }
}
