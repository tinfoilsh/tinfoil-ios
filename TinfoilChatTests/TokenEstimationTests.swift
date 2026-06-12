//
//  TokenEstimationTests.swift
//  TinfoilChatTests
//
//  Verifies the token estimation and context budgeting heuristics match the
//  webapp's `token-estimation.ts` behavior so both platforms archive the
//  same messages.
//

import Foundation
import Testing
@testable import TinfoilChat

struct TokenEstimationTests {

    private func message(role: MessageRole = .user, content: String) -> Message {
        Message(id: UUID().uuidString, role: role, content: content, timestamp: Date())
    }

    @Test func estimatesTokensFromCharacterCount() {
        #expect(TokenEstimation.estimateTokenCount(nil) == 0)
        #expect(TokenEstimation.estimateTokenCount("") == 0)
        #expect(TokenEstimation.estimateTokenCount("abcd") == 1)
        #expect(TokenEstimation.estimateTokenCount("abcde") == 2)
    }

    @Test func parsesContextWindowStrings() {
        #expect(TokenEstimation.parseContextWindowTokens("64k tokens") == 64_000)
        #expect(TokenEstimation.parseContextWindowTokens("256K tokens") == 256_000)
        #expect(TokenEstimation.parseContextWindowTokens("32000") == 32_000)
        #expect(TokenEstimation.parseContextWindowTokens(nil) == Constants.Context.defaultContextWindowTokens)
        #expect(TokenEstimation.parseContextWindowTokens("unknown") == Constants.Context.defaultContextWindowTokens)
    }

    @Test func budgetIsUsageRatioOfWindow() {
        #expect(TokenEstimation.contextTokenBudget("100k tokens") == 90_000)
        #expect(TokenEstimation.contextTokenBudget(nil) ==
                Int(Double(Constants.Context.defaultContextWindowTokens) * Constants.Context.contextWindowUsageRatio))
    }

    @Test func includesAttachmentAndToolCallTokens() {
        var msg = message(content: "abcd")
        msg.attachments = [
            Attachment(type: .document, fileName: "doc.txt", textContent: "abcdefgh")
        ]
        msg.toolCalls = [GenUIToolCall(id: "1", name: "abcd", arguments: "abcd")]
        // content 1 + attachment 2 + tool name 1 + tool args 1
        #expect(TokenEstimation.estimateMessageTokens(msg) == 5)
    }

    @Test func archivesOldestMessagesBeyondBudget() {
        // Each message is 40 chars = 10 tokens
        let messages = (0..<5).map { _ in message(content: String(repeating: "a", count: 40)) }

        // Budget fits exactly two messages
        #expect(TokenEstimation.findContextStartIndex(messages: messages, budgetTokens: 20) == 3)
        // Everything fits
        #expect(TokenEstimation.findContextStartIndex(messages: messages, budgetTokens: 50) == 0)
    }

    @Test func newestMessageIsAlwaysKept() {
        let messages = [
            message(content: String(repeating: "a", count: 40)),
            message(content: String(repeating: "a", count: 400)),
        ]
        // Budget smaller than even the newest message alone
        #expect(TokenEstimation.findContextStartIndex(messages: messages, budgetTokens: 10) == 1)
        let selected = TokenEstimation.selectMessagesWithinBudget(messages, contextWindow: "1")
        #expect(selected.count == 1)
        #expect(selected[0].id == messages[1].id)
    }

    @Test func trailingEmptyPlaceholderDoesNotEvictLatestUserMessage() {
        let messages = [
            message(content: String(repeating: "a", count: 40)),
            message(content: String(repeating: "a", count: 400)),
            message(role: .assistant, content: ""),
        ]
        // Budget smaller than the latest user message alone: the user message
        // must still be kept alongside the streaming placeholder.
        #expect(TokenEstimation.findContextStartIndex(messages: messages, budgetTokens: 10) == 1)
    }

    @Test func emptyMessagesSelectsNothing() {
        #expect(TokenEstimation.findContextStartIndex(messages: [], budgetTokens: 100) == 0)
        #expect(TokenEstimation.selectMessagesWithinBudget([], contextWindow: nil).isEmpty)
    }
}
