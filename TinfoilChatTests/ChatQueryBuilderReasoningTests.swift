//
//  ChatQueryBuilderReasoningTests.swift
//  TinfoilChatTests
//
//  Verifies that ChatQueryBuilder turns a model's `reasoningConfig` plus the
//  user's selected effort/toggle into the right top-level extra body fields,
//  matching the webapp's behavior. Covers:
//
//   - DeepSeek-shaped config: nested `chat_template_kwargs` with effortMap
//     translating low/medium → high, high → max.
//   - Toggle-off path: the disable block is emitted instead of enable.
//   - GPT-OSS-shaped config: top-level `reasoning_effort`, no effortMap.
//   - Models without `reasoningConfig`: no extra body.
//

import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

struct ChatQueryBuilderReasoningTests {

    private func deepseekConfig() -> ReasoningConfig {
        ReasoningConfig(
            supportsEffort: true,
            supportsToggle: true,
            defaultEnabled: true,
            effortMap: ["low": "high", "medium": "high", "high": "max"],
            params: [
                "/v1/chat/completions": ReasoningEndpointParams(
                    enable: .object([
                        "chat_template_kwargs": .object([
                            "thinking": .bool(true),
                            "reasoning_effort": .string("$EFFORT"),
                        ])
                    ]),
                    disable: .object([
                        "chat_template_kwargs": .object([
                            "thinking": .bool(false)
                        ])
                    ])
                )
            ],
            reasoningHistoryPolicy: .none
        )
    }

    private func gptOssConfig() -> ReasoningConfig {
        ReasoningConfig(
            supportsEffort: true,
            supportsToggle: false,
            defaultEnabled: nil,
            effortMap: nil,
            params: [
                "/v1/chat/completions": ReasoningEndpointParams(
                    enable: .object([
                        "reasoning_effort": .string("$EFFORT")
                    ]),
                    disable: nil
                )
            ],
            reasoningHistoryPolicy: .toolCallOnly
        )
    }

    private func gemmaConfig() -> ReasoningConfig {
        ReasoningConfig(
            supportsEffort: false,
            supportsToggle: true,
            defaultEnabled: true,
            effortMap: nil,
            params: [
                "/v1/chat/completions": ReasoningEndpointParams(
                    enable: .object([
                        "chat_template_kwargs": .object([
                            "enable_thinking": .bool(true)
                        ])
                    ]),
                    disable: .object([
                        "chat_template_kwargs": .object([
                            "enable_thinking": .bool(false)
                        ])
                    ])
                )
            ],
            reasoningHistoryPolicy: .toolCallOnly
        )
    }

    private func preservedHistoryConfig() -> ReasoningConfig {
        ReasoningConfig(
            supportsEffort: nil,
            supportsToggle: nil,
            defaultEnabled: nil,
            effortMap: nil,
            params: nil,
            reasoningHistoryPolicy: .all
        )
    }

    private func model(
        id: String,
        contextWindow: String = "256k tokens",
        contextWindowTokens: Int? = nil,
        reasoningConfig: ReasoningConfig?
    ) -> ModelType {
        ModelType(from: AppModelConfig(
            modelName: id,
            image: "",
            name: id,
            nameShort: id,
            description: "",
            details: "",
            parameters: "",
            contextWindow: contextWindow,
            contextWindowTokens: contextWindowTokens,
            type: "chat",
            chat: true,
            paid: true,
            multimodal: false,
            toolCalling: true,
            attributes: ["smart"],
            reasoningConfig: reasoningConfig
        ))
    }

    @Test func reasoningHistoryPolicyDecodesFromModelConfig() throws {
        let data = Data(#"{"reasoningHistoryPolicy":"tool-call-only"}"#.utf8)
        let config = try JSONDecoder().decode(ReasoningConfig.self, from: data)

        #expect(config.reasoningHistoryPolicy == .toolCallOnly)
    }

    @Test func legacyModelConfigFallsBackToDisplayContextWindow() throws {
        let data = Data(
            #"""
            {
              "modelName": "legacy",
              "image": "",
              "name": "Legacy",
              "nameShort": "Legacy",
              "description": "",
              "details": "",
              "parameters": "",
              "contextWindow": "128k tokens",
              "type": "chat",
              "paid": true,
              "multimodal": false
            }
            """#.utf8
        )
        let config = try JSONDecoder().decode(AppModelConfig.self, from: data)

        #expect(ModelType(from: config).contextWindowTokens == 128_000)
    }

    @Test func unknownReasoningHistoryPolicyFallsBackSafely() throws {
        let data = Data(#"{"reasoningHistoryPolicy":"future-policy"}"#.utf8)
        let config = try JSONDecoder().decode(ReasoningConfig.self, from: data)

        #expect(config.reasoningHistoryPolicy == .none)
    }

    @Test func deepseekLowEffortMapsToHighInsideChatTemplateKwargs() {
        let body = ChatQueryBuilder.makeReasoningExtraBody(
            reasoningConfig: deepseekConfig(),
            reasoningEffort: .low,
            thinkingEnabled: true
        )

        #expect(body == [
            "chat_template_kwargs": .object([
                "thinking": .bool(true),
                "reasoning_effort": .string("high"),
            ])
        ])
    }

    @Test func deepseekHighEffortMapsToMax() {
        let body = ChatQueryBuilder.makeReasoningExtraBody(
            reasoningConfig: deepseekConfig(),
            reasoningEffort: .high,
            thinkingEnabled: true
        )

        #expect(body == [
            "chat_template_kwargs": .object([
                "thinking": .bool(true),
                "reasoning_effort": .string("max"),
            ])
        ])
    }

    @Test func toggleOffEmitsDisableBlock() {
        let body = ChatQueryBuilder.makeReasoningExtraBody(
            reasoningConfig: deepseekConfig(),
            reasoningEffort: .high,
            thinkingEnabled: false
        )

        #expect(body == [
            "chat_template_kwargs": .object([
                "thinking": .bool(false)
            ])
        ])
    }

    @Test func gptOssEmitsTopLevelReasoningEffortWithoutMapping() {
        let body = ChatQueryBuilder.makeReasoningExtraBody(
            reasoningConfig: gptOssConfig(),
            reasoningEffort: .medium,
            thinkingEnabled: true
        )

        #expect(body == [
            "reasoning_effort": .string("medium")
        ])
    }

    @Test func gemmaToggleOnlyEmitsEnableWithoutEffort() {
        let body = ChatQueryBuilder.makeReasoningExtraBody(
            reasoningConfig: gemmaConfig(),
            reasoningEffort: .high,
            thinkingEnabled: true
        )

        #expect(body == [
            "chat_template_kwargs": .object([
                "enable_thinking": .bool(true)
            ])
        ])
    }

    @Test func nilReasoningConfigYieldsNoExtraBody() {
        let body = ChatQueryBuilder.makeReasoningExtraBody(
            reasoningConfig: nil,
            reasoningEffort: .medium,
            thinkingEnabled: true
        )

        #expect(body == nil)
    }

    @Test @MainActor
    func extraBodyMakesItIntoEncodedChatQuery() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "deepseek-v4-pro",
            systemPrompt: "you are tin",
            rules: "",
            conversationMessages: [],
            stream: false,
            reasoningConfig: deepseekConfig(),
            reasoningEffort: .high,
            thinkingEnabled: true
        )

        let data = try JSONEncoder().encode(query)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let kwargs = object?["chat_template_kwargs"] as? [String: Any]

        #expect(kwargs?["thinking"] as? Bool == true)
        #expect(kwargs?["reasoning_effort"] as? String == "max")
    }

    @Test @MainActor
    func piiCheckCoexistsWithWebSearchAndReasoning() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "",
            rules: "",
            conversationMessages: [],
            stream: false,
            webSearchEnabled: true,
            piiCheckEnabled: true,
            reasoningConfig: gptOssConfig(),
            reasoningEffort: .high,
            genUIEnabled: false
        )

        let data = try JSONEncoder().encode(query)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["web_search_options"] as? [String: Any] != nil)
        #expect(object["pii_check_options"] as? [String: Any] != nil)
        #expect(object["reasoning_effort"] as? String == "high")
    }

    @Test @MainActor
    func piiCheckCoexistsWithAutoModelOptions() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "",
            rules: "",
            conversationMessages: [],
            stream: false,
            piiCheckEnabled: true,
            genUIEnabled: false,
            autoCandidates: [model(id: "gpt-oss-120b", reasoningConfig: gptOssConfig())]
        )

        let data = try JSONEncoder().encode(query)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object[AutoModel.optionsField] as? [[String: Any]] != nil)
        #expect(object["pii_check_options"] as? [String: Any] != nil)
    }

    @Test @MainActor
    func emptyPromptDoesNotEmitSystemMessage() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "",
            rules: "",
            conversationMessages: [
                Message(role: .user, content: "hello")
            ],
            stream: false,
            genUIEnabled: false
        )

        let messages = try encodedMessages(from: query)
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hello")
    }

    @Test @MainActor
    func systemRoleIsUsedForDeepSeekAndAuto() throws {
        let deepseek = model(id: "deepseek-v4-flash", reasoningConfig: nil)
        let gptOss = model(id: "gpt-oss-120b", reasoningConfig: nil)

        for (modelId, candidates) in [
            ("deepseek-v4-flash", nil),
            ("gpt-oss-120b", [gptOss, deepseek]),
        ] as [(String, [ModelType]?)] {
            let query = ChatQueryBuilder.buildQuery(
                modelId: modelId,
                systemPrompt: "be helpful",
                rules: "",
                conversationMessages: [
                    Message(role: .user, content: "hello")
                ],
                stream: false,
                genUIEnabled: false,
                autoCandidates: candidates
            )

            let messages = try encodedMessages(from: query)
            #expect(messages.count == 2)
            #expect(messages[0]["role"] as? String == "system")
            #expect(messages[0]["content"] as? String == "be helpful")
            #expect(messages[1]["role"] as? String == "user")
            #expect(messages[1]["content"] as? String == "hello")
        }
    }

    @Test @MainActor
    func preservedReasoningIsReturnedWithAssistantContentAndToolCalls() throws {
        var assistant = Message(role: .assistant, content: "answer", thoughts: "reasoning")
        assistant.toolCalls = [
            GenUIToolCall(id: "call_1", name: "render_chart", arguments: "{\"value\":1}")
        ]
        let query = ChatQueryBuilder.buildQuery(
            modelId: "kimi-k3",
            systemPrompt: "",
            rules: "",
            conversationMessages: [assistant],
            stream: false,
            reasoningConfig: preservedHistoryConfig(),
            genUIEnabled: false
        )

        let messages = try encodedMessages(from: query)
        let encodedAssistant = try #require(messages.first)
        #expect(encodedAssistant["role"] as? String == "assistant")
        #expect(encodedAssistant["content"] as? String == "answer")
        #expect(encodedAssistant["reasoning_content"] as? String == "reasoning")
        #expect((encodedAssistant["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(messages.last?["role"] as? String == "tool")
    }

    @Test @MainActor
    func reasoningOnlyAssistantIsKeptWhenHistoryIsRequired() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "kimi-k3",
            systemPrompt: "",
            rules: "",
            conversationMessages: [
                Message(role: .assistant, content: "", thoughts: "reasoning only")
            ],
            stream: false,
            reasoningConfig: preservedHistoryConfig(),
            genUIEnabled: false
        )

        let messages = try encodedMessages(from: query)
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "assistant")
        #expect(messages.first?["reasoning_content"] as? String == "reasoning only")
    }

    @Test @MainActor
    func reasoningIsOmittedForNonToolCallAssistantUnderToolCallOnlyPolicy() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "",
            rules: "",
            conversationMessages: [
                Message(role: .assistant, content: "answer", thoughts: "reasoning")
            ],
            stream: false,
            reasoningConfig: gptOssConfig(),
            genUIEnabled: false
        )

        let messages = try encodedMessages(from: query)
        #expect(messages.first?["reasoning_content"] == nil)
    }

    @Test @MainActor
    func toolCallPolicyPreservesOnlyToolCallReasoning() throws {
        var toolCallAssistant = Message(role: .assistant, content: "", thoughts: "keep this")
        toolCallAssistant.toolCalls = [
            GenUIToolCall(id: "call_1", name: "render_chart", arguments: "{}")
        ]
        let query = ChatQueryBuilder.buildQuery(
            modelId: "gpt-oss-120b",
            systemPrompt: "",
            rules: "",
            conversationMessages: [
                Message(role: .assistant, content: "ordinary", thoughts: "omit this"),
                toolCallAssistant,
            ],
            stream: false,
            reasoningConfig: gptOssConfig(),
            genUIEnabled: false
        )

        let messages = try encodedMessages(from: query)
        #expect(messages.first?["reasoning_content"] == nil)
        #expect(messages[1]["reasoning_content"] as? String == "keep this")
    }

    @Test @MainActor
    func autoPreservesReasoningWhenAnyCandidateRequiresIt() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "glm-5-2",
            systemPrompt: "",
            rules: "",
            conversationMessages: [
                Message(role: .assistant, content: "answer", thoughts: "reasoning")
            ],
            stream: false,
            genUIEnabled: false,
            autoCandidates: [
                model(id: "glm-5-2", reasoningConfig: nil),
                model(id: "kimi-k3", reasoningConfig: preservedHistoryConfig()),
            ]
        )

        let messages = try encodedMessages(from: query)
        #expect(messages.first?["reasoning_content"] as? String == "reasoning")
    }

    @Test func autoSelectionUsesTheSmallestCandidateContextWindow() {
        let selection = ModelSelection(
            representative: model(id: "large", contextWindow: "256k tokens", reasoningConfig: nil),
            autoCandidates: [
                model(id: "large", contextWindow: "256k tokens", reasoningConfig: nil),
                model(id: "small", contextWindow: "128k tokens", reasoningConfig: nil),
            ]
        )

        #expect(selection.contextWindowTokens == 128_000)
    }

    @Test func autoSelectionPrefersNumericContextWindow() {
        let selection = ModelSelection(
            representative: model(
                id: "large",
                contextWindow: "1k tokens",
                contextWindowTokens: 256_000,
                reasoningConfig: nil
            ),
            autoCandidates: [
                model(
                    id: "large",
                    contextWindow: "1k tokens",
                    contextWindowTokens: 256_000,
                    reasoningConfig: nil
                ),
                model(
                    id: "small",
                    contextWindow: "999k tokens",
                    contextWindowTokens: 128_000,
                    reasoningConfig: nil
                ),
            ]
        )

        #expect(selection.contextWindowTokens == 128_000)
    }

    @Test func invalidNumericContextWindowFallsBackToDisplayValue() {
        let candidate = model(
            id: "legacy",
            contextWindow: "128k tokens",
            contextWindowTokens: 1,
            reasoningConfig: nil
        )

        #expect(candidate.contextWindowTokens == 128_000)
    }

    private func encodedMessages(from query: ChatQuery) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(query)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["messages"] as? [[String: Any]] ?? []
    }
}
