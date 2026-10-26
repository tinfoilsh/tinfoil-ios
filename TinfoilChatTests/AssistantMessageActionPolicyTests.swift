//
//  AssistantMessageActionPolicyTests.swift
//  TinfoilChatTests
//

import Testing
@testable import TinfoilChat

struct AssistantMessageActionPolicyTests {
    @Test func regenerationRequiresTheFinalIdleAssistantResponse() {
        #expect(AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: true,
            canGenerateInCurrentChat: true,
            isLoading: false,
            messageIndex: 1,
            isRateLimitError: false,
            isHourlyLimitError: false
        ))

        #expect(!AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: false,
            canGenerateInCurrentChat: true,
            isLoading: false,
            messageIndex: 1,
            isRateLimitError: false,
            isHourlyLimitError: false
        ))
        #expect(!AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: true,
            canGenerateInCurrentChat: true,
            isLoading: true,
            messageIndex: 1,
            isRateLimitError: false,
            isHourlyLimitError: false
        ))
        #expect(!AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: true,
            canGenerateInCurrentChat: false,
            isLoading: false,
            messageIndex: 1,
            isRateLimitError: false,
            isHourlyLimitError: false
        ))
        #expect(!AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: true,
            canGenerateInCurrentChat: true,
            isLoading: false,
            messageIndex: 0,
            isRateLimitError: false,
            isHourlyLimitError: false
        ))
    }

    @Test func dailyLimitKeepsUpgradeWhileHourlyLimitAllowsRegeneration() {
        #expect(!AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: true,
            canGenerateInCurrentChat: true,
            isLoading: false,
            messageIndex: 1,
            isRateLimitError: true,
            isHourlyLimitError: false
        ))
        #expect(AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: true,
            canGenerateInCurrentChat: true,
            isLoading: false,
            messageIndex: 1,
            isRateLimitError: true,
            isHourlyLimitError: true
        ))
    }

    @Test func failedResponseContinuesWhatItStreamedOrStartsOver() {
        #expect(AssistantMessageActionPolicy.streamErrorRetry(
            canRegenerate: true,
            hasPartialResponse: true
        ) == .continueResponse)
        #expect(AssistantMessageActionPolicy.streamErrorRetry(
            canRegenerate: true,
            hasPartialResponse: false
        ) == .regenerate)
        #expect(AssistantMessageActionPolicy.streamErrorRetry(
            canRegenerate: false,
            hasPartialResponse: true
        ) == nil)
    }

    @Test func onlyTextOrToolCallsCanBeContinued() {
        var response = Message(role: .assistant, content: "", thoughts: "Thinking only")
        #expect(!response.hasContinuableResponse)

        response.toolCalls = [GenUIToolCall(id: "call_1", name: "widget", arguments: "{}")]
        #expect(response.hasContinuableResponse)

        #expect(Message(role: .assistant, content: "Partial").hasContinuableResponse)
        #expect(!Message(role: .user, content: "Question").hasContinuableResponse)
    }
}
