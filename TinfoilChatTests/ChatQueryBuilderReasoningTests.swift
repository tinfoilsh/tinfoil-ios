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
            ]
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
            ]
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
            ]
        )
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

    @Test func extraBodyMakesItIntoEncodedChatQuery() throws {
        let query = ChatQueryBuilder.buildQuery(
            modelId: "deepseek-v4-pro",
            systemPrompt: "you are tin",
            rules: "",
            conversationMessages: [],
            maxMessages: 10,
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
}
