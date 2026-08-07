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

    struct RequestBudget {
        let contextWindows: [String]
        let systemInstructions: String
        let toolDefinitions: String
        let timeReminder: String?
        let isMultimodal: Bool
        let maxMessages: Int
    }

    enum RequestBudgetError: LocalizedError, Equatable {
        case fixedOverheadTooLarge
        case newestTurnTooLarge

        var errorDescription: String? {
            switch self {
            case .fixedOverheadTooLarge:
                return "This chat's instructions and enabled tools are too large for the model's request limit. Disable a tool or choose a model with a larger context window."
            case .newestTurnTooLarge:
                return "Your latest message is too large for this model's request limit. Remove an attachment, shorten the message, or choose a model with a larger context window."
            }
        }
    }

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
        guard let match = contextWindow.firstMatch(of: /(\d+)([kK])?/),
              let value = Int(match.1) else {
            return Constants.Context.defaultContextWindowTokens
        }
        return match.2 != nil ? value * 1000 : value
    }

    /// Applies the usage ratio to the parsed window size, keeping the
    /// remainder of the window reserved for the model's reply, the system
    /// prompt, and the slack in our character-based estimates.
    static func contextTokenBudget(_ contextWindow: String?) -> Int {
        contextTokenBudget([contextWindow ?? ""])
    }

    static func contextTokenBudget(_ contextWindows: [String]) -> Int {
        let safeContextTokens = Int(floor(
            Double(minimumContextWindowTokens(contextWindows)) * Constants.Context.contextWindowUsageRatio
        ))
        return max(
            0,
            safeContextTokens
                - Constants.Context.outputReserveTokens
                - Constants.Context.requestOverheadTokens
        )
    }

    /// Estimate the prompt tokens contributed by a single message, including
    /// tool calls and attachment text. Thoughts are excluded because they are
    /// never sent back in prompts. Search reasoning is counted even though
    /// this app's query builder doesn't resend it yet: the webapp sends it
    /// for multi-turn context and counts it, and matching its estimate keeps
    /// the archive boundary identical across platforms (erring toward a
    /// smaller prompt, never an overflow).
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

    static func minimumContextWindowTokens(_ contextWindows: [String]) -> Int {
        contextWindows
            .map(parseContextWindowTokens)
            .min() ?? Constants.Context.defaultContextWindowTokens
    }

    static func estimateRequestMessageTokens(_ message: Message, isMultimodal: Bool) -> Int {
        if message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty {
            return 0
        }
        var tokens = estimateTokenCount(message.content) + Constants.Context.messageOverheadTokens
        if let searchReasoning = message.searchReasoning {
            tokens += estimateTokenCount(searchReasoning)
        }
        for toolCall in message.toolCalls {
            tokens += estimateTokenCount(toolCall.id)
            tokens += estimateTokenCount(toolCall.name)
            tokens += estimateTokenCount(toolCall.arguments.isEmpty ? "{}" : toolCall.arguments)
            tokens += estimateTokenCount(Constants.Context.toolResult)
            tokens += Constants.Context.messageOverheadTokens
        }
        for attachment in message.attachments {
            switch attachment.type {
            case .document:
                if let text = attachment.textContent, !text.isEmpty {
                    let wrapped = "Document title: \(attachment.fileName)\nDocument contents:\n\(text)"
                    tokens += estimateTokenCount(wrapped)
                }
            case .image:
                if isMultimodal, attachment.base64 != nil {
                    tokens += Constants.Context.imageInputAllowanceTokens
                } else if let description = attachment.description, !description.isEmpty {
                    let wrapped = "Image: \(attachment.fileName)\nDescription:\n\(description)"
                    tokens += estimateTokenCount(wrapped)
                }
            }
        }
        return tokens
    }

    static func selectMessagesForRequest(
        _ messages: [Message],
        budget: RequestBudget
    ) throws -> [Message] {
        let contextTokens = Int(floor(
            Double(minimumContextWindowTokens(budget.contextWindows))
                * Constants.Context.contextWindowUsageRatio
        ))
        var fixedTokens = Constants.Context.requestOverheadTokens
            + Constants.Context.outputReserveTokens
            + estimateTokenCount(budget.systemInstructions)
            + estimateTokenCount(budget.toolDefinitions)
        var fixedMessages = budget.systemInstructions.isEmpty ? 0 : 1
        if !budget.systemInstructions.isEmpty {
            fixedTokens += Constants.Context.messageOverheadTokens
        }
        if let timeReminder = budget.timeReminder {
            fixedTokens += estimateTokenCount(timeReminder) + Constants.Context.messageOverheadTokens
            fixedMessages += 1
        }
        let availableTokens = max(0, contextTokens - fixedTokens)
        let availableMessages = max(0, budget.maxMessages - fixedMessages)
        guard fixedTokens <= contextTokens, fixedMessages <= budget.maxMessages else {
            throw RequestBudgetError.fixedOverheadTooLarge
        }
        guard !messages.isEmpty else { return [] }
        let groups = requestTurnGroups(messages)
        guard let newestGroup = groups.last else { return [] }

        let newestTokens = newestGroup.reduce(0) {
            $0 + estimateRequestMessageTokens(messages[$1], isMultimodal: budget.isMultimodal)
        }
        let newestMessageCount = newestGroup.reduce(0) {
            $0 + requestMessageCount(messages[$1])
        }
        guard newestTokens <= availableTokens, newestMessageCount <= availableMessages else {
            throw RequestBudgetError.newestTurnTooLarge
        }

        var selectedStart = newestGroup.lowerBound
        var usedTokens = 0
        var usedMessages = 0
        for group in groups.reversed() {
            let groupTokens = group.reduce(0) {
                $0 + estimateRequestMessageTokens(messages[$1], isMultimodal: budget.isMultimodal)
            }
            let groupMessageCount = group.reduce(0) {
                $0 + requestMessageCount(messages[$1])
            }
            guard usedTokens + groupTokens <= availableTokens,
                  usedMessages + groupMessageCount <= availableMessages else {
                break
            }
            usedTokens += groupTokens
            usedMessages += groupMessageCount
            selectedStart = group.lowerBound
        }
        return Array(messages[selectedStart...])
    }

    private static func requestTurnGroups(_ messages: [Message]) -> [Range<Int>] {
        guard !messages.isEmpty else { return [] }
        var starts = [0]
        for index in messages.indices.dropFirst() where messages[index].role == .user {
            starts.append(index)
        }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : messages.count
            return start..<end
        }
    }

    private static func requestMessageCount(_ message: Message) -> Int {
        if message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty {
            return 0
        }
        return 1 + message.toolCalls.count
    }

    /// Returns the index of the first message (from the end) that fits within
    /// the token budget. Messages before this index are "archived" and
    /// excluded from the prompt. The most recent substantive message is always
    /// included, even if it alone exceeds the budget: zero-token messages
    /// (like the empty assistant placeholder appended before streaming) must
    /// not satisfy that guarantee on their own, or the latest user message
    /// could be dropped from the prompt.
    static func findContextStartIndex(messages: [Message], budgetTokens: Int) -> Int {
        var usedTokens = 0
        var hasIncludedSubstantiveMessage = false
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let messageTokens = estimateMessageTokens(messages[i])
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
    static func selectMessagesWithinBudget(_ messages: [Message], contextWindow: String?) -> [Message] {
        let budget = contextTokenBudget(contextWindow)
        return Array(messages[findContextStartIndex(messages: messages, budgetTokens: budget)...])
    }
}
