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

    /// Uses the same chars-per-token heuristic as the webapp (~4 characters
    /// per token for typical English text), rounding up so short fragments
    /// still cost at least one token. Deliberately not a real tokenizer:
    /// archiving only needs both platforms to agree, not exact counts.
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
        guard let match = contextWindow.firstMatch(
            of: /^\s*(\d+(?:\.\d+)?)\s*([kKmM])?(?:\s*tokens?)?\s*$/
        ), let value = Double(match.1) else {
            return Constants.Context.defaultContextWindowTokens
        }

        let multiplier: Double
        switch match.2?.lowercased() {
        case "k":
            multiplier = 1_000
        case "m":
            multiplier = 1_000_000
        default:
            multiplier = 1
        }

        let tokens = value * multiplier
        guard tokens.isFinite,
              tokens >= Double(Constants.Context.minimumContextWindowTokens),
              tokens < Double(Int.max) else {
            return Constants.Context.defaultContextWindowTokens
        }
        return Int(tokens)
    }

    /// Applies the usage ratio to the configured window size, keeping the
    /// remainder of the window reserved for the model's reply, the system
    /// prompt, and the slack in our character-based estimates.
    static func contextTokenBudget(_ contextWindowTokens: Int?) -> Int {
        let tokens = contextWindowTokens ?? Constants.Context.defaultContextWindowTokens
        return Int(floor(Double(tokens) * Constants.Context.contextWindowUsageRatio))
    }

    /// Estimate the prompt tokens contributed by a single message, including
    /// tool calls and attachment text. Reasoning is counted when the selected
    /// model requires it to be returned in subsequent requests. Search
    /// reasoning is counted even though this app's query builder doesn't resend
    /// it yet: the webapp sends it for multi-turn context and counts it, and
    /// matching its estimate keeps the archive boundary identical across
    /// platforms (erring toward a smaller prompt, never an overflow).
    static func estimateMessageTokens(
        _ message: Message,
        reasoningHistoryPolicy: ReasoningHistoryPolicy = .none
    ) -> Int {
        var tokens = estimateTokenCount(message.content)
        if reasoningHistoryPolicy.includesReasoning(for: message) {
            tokens += estimateTokenCount(message.reasoningContentForHistory)
        }
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
    /// excluded from the prompt. The most recent substantive message is always
    /// included, even if it alone exceeds the budget: zero-token messages
    /// (like the empty assistant placeholder appended before streaming) must
    /// not satisfy that guarantee on their own, or the latest user message
    /// could be dropped from the prompt.
    static func findContextStartIndex(
        messages: [Message],
        budgetTokens: Int,
        reasoningHistoryPolicy: ReasoningHistoryPolicy = .none
    ) -> Int {
        var usedTokens = 0
        var hasIncludedSubstantiveMessage = false
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let messageTokens = estimateMessageTokens(
                messages[i],
                reasoningHistoryPolicy: reasoningHistoryPolicy
            )
            usedTokens += messageTokens
            if usedTokens > budgetTokens && hasIncludedSubstantiveMessage {
                return i + 1
            }
            if messageTokens > 0 {
                hasIncludedSubstantiveMessage = true
            }
        }
        return 0
    }

    /// The trailing slice of messages that fits within the model's context
    /// token budget.
    static func selectMessagesWithinBudget(
        _ messages: [Message],
        contextWindowTokens: Int?,
        reasoningHistoryPolicy: ReasoningHistoryPolicy = .none
    ) -> [Message] {
        let budget = contextTokenBudget(contextWindowTokens)
        return Array(messages[findContextStartIndex(
            messages: messages,
            budgetTokens: budget,
            reasoningHistoryPolicy: reasoningHistoryPolicy
        )...])
    }
}
