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
        type: "chat",
        chat: true,
        paid: false,
        multimodal: false,
        toolCalling: nil,
        chatConfig: ChatModelConfig(
            contextWindowTokens: 64_000,
            attributes: nil,
            descriptionShort: nil,
            reasoningConfig: nil
        )
    )
)

struct ProjectChatEncodingTests {
    @Test @MainActor
    func harnessChatSurvivesAnIOSReplyAndSync() throws {
        let json = """
        {
          "id":"shared-chat","title":"Research","titleState":"manual",
          "createdAt":"2026-10-19T00:00:00Z","updatedAt":"2026-10-19T00:00:00Z",
          "projectId":"project-1","presetId":"user:shared-preset","webSearchEnabled":true,
          "clock":12,"writer":"harness","clockVersion":7,
          "messages":[
            {
              "id":"question","role":"user","content":"Read these files",
              "createdAt":"2026-10-19T00:00:00Z",
              "attachments":[
                {"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"image","fileName":"photo.png","mimeType":"image/png","encryptionKey":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","thumbnailBase64":"dGh1bWI="},
                {"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"document","fileName":"paper.pdf","encryptionKey":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=","pageCount":2}
              ]
            },
            \(HarnessMessageFixture.json)
          ]
        }
        """
        var stored = try JSONDecoder().decode(StoredChat.self, from: Data(json.utf8))
        stored.modelType = testModel
        var chat = try #require(stored.toChat())
        chat.messages.append(Message(role: .assistant, content: "Follow-up from iOS."))
        let uploaded = try JSONDecoder().decode(StoredChat.self, from: JSONEncoder().encode(StoredChat(from: chat, syncVersion: 7)))
        #expect(uploaded.id == "shared-chat")
        #expect(uploaded.messages.map(\.content) == [
            "Read these files", "Before search.The sample has 73 participants.", "Follow-up from iOS.",
        ])
        #expect(uploaded.projectId == "project-1")
        #expect(uploaded.promptPresetId == "user:shared-preset")
        #expect(uploaded.messages[0].attachments.map(\.encryptionKey) == [
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=", "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=",
        ])
        #expect(uploaded.messages[0].attachments.map(\.id) == [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ])
        #expect(uploaded.messages[0].timestamp == Date(timeIntervalSince1970: 1_792_368_000))
        let originalTools = stored.messages[1].timeline?.filter { $0.objectValue?["type"]?.stringValue == "tool_call" }
        #expect(uploaded.messages[1].timeline?.filter { $0.objectValue?["type"]?.stringValue == "tool_call" } == originalTools)
        #expect(uploaded.clock == 12)
        #expect(uploaded.writer == "harness")
        #expect(uploaded.clockVersion == 7)
    }

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

    @Test @MainActor
    func storedChatRoundTripsPromptPresetId() throws {
        var chat = Chat.create(id: "chat-1", modelType: testModel)
        chat.promptPresetId = "user:shared-preset"

        let data = try JSONEncoder().encode(StoredChat(from: chat))
        let stored = try JSONDecoder().decode(StoredChat.self, from: data)
        let decoded = try #require(stored.toChat())

        #expect(stored.promptPresetId == "user:shared-preset")
        #expect(decoded.promptPresetId == "user:shared-preset")
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
