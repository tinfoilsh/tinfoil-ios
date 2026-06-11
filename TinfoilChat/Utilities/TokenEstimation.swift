//
//  TokenEstimation.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import Foundation

/// Heuristic token estimation and context-window budgeting.
///
/// Mirrors the webapp's `src/utils/token-estimation.ts` so both platforms
/// archive the same messages for a given conversation and model.
enum TokenEstimation {

    /// Roughly estimate token count based on character length.
    static func estimateTokenCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.count) / Constants.Context.charsPerToken))
    }

    /// Parse a model's human-readable context window string (e.g. "64k tokens")
    /// into a token count, falling back to the default when unknown.
    static func parseContextWindowTokens(_ contextWindow: String?) -> Int {
        guard let contextWindow, !contextWindow.isEmpty else {
            return Constants.Context.defaultContextWindowTokens
        }
        guard let match = contextWindow.firstMatch(of: /(\d+)([kK])?/),
              let value = Int(match.1) else {
            return Constants.Context.defaultContextWindowTokens
        }
        return match.2 != nil ? value * 1000 : value
    }

    /// The token budget available to conversation history for a model.
    static func contextTokenBudget(_ contextWindow: String?) -> Int {
        Int(floor(Double(parseContextWindowTokens(contextWindow)) * Constants.Context.contextWindowUsageRatio))
    }

    /// Estimate the prompt tokens contributed by a single message, including
    /// tool calls and attachment text. Thoughts are excluded because they are
    /// never sent back in prompts.
    static func estimateMessageTokens(_ message: Message) -> Int {
        var tokens = estimateTokenCount(message.content)
        if let searchReasoning = message.searchReasoning {
            tokens += estimateTokenCount(searchReasoning)
        }
        for toolCall in message.toolCalls {
            tokens += estimateTokenCount(toolCall.name)
            tokens += estimateTokenCount(toolCall.arguments)
        }
        for attachment in message.attachments {
            tokens += estimateTokenCount(attachment.textContent)
            tokens += estimateTokenCount(attachment.description)
        }
        return tokens
    }

    /// Returns the index of the first message (from the end) that fits within
    /// the token budget. Messages before this index are "archived" and
    /// excluded from the prompt. The most recent message is always included,
    /// even if it alone exceeds the budget.
    static func findContextStartIndex(messages: [Message], budgetTokens: Int) -> Int {
        var usedTokens = 0
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            usedTokens += estimateMessageTokens(messages[i])
            if usedTokens > budgetTokens && i < messages.count - 1 {
                return i + 1
            }
        }
        return 0
    }

    /// The trailing slice of messages that fits within the model's context
    /// token budget.
    static func selectMessagesWithinBudget(_ messages: [Message], contextWindow: String?) -> [Message] {
        let budget = contextTokenBudget(contextWindow)
        return Array(messages[findContextStartIndex(messages: messages, budgetTokens: budget)...])
    }
}
