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
}
