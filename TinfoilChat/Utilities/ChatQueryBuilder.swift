//
//  ChatQueryBuilder.swift
//  TinfoilChat
//
//  Created on 19/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import OpenAI

/// Helper for building ChatQuery with model-specific system prompt injection
///
/// **System Prompt Handling by Model:**
/// - **Llama** (llama-free, llama3-3-70b): Uses system role in messages array
/// - **GPT-OSS** (gpt-oss-120b): Uses system role in messages array
/// - **Qwen** (qwen2-5-72b): Uses system role in messages array (ChatML format)
/// - **DeepSeek** (deepseek-r1-0528): Prepends to first user message (not trained with system role)
/// - **Mistral** (mistral-small-3-1-24b): Prepends to first user message ([INST] format)
/// - **Unknown models**: Prepends to first user message (safe default)
struct ChatQueryBuilder {

    /// Build ChatQuery with model-appropriate system prompt and rules injection
    /// - Parameters:
    ///   - modelId: The model identifier (e.g., "llama-free", "deepseek-r1-0528")
    ///   - systemPrompt: The base system prompt with placeholders already replaced
    ///   - rules: Additional rules to include (will be combined with system prompt based on model)
    ///   - conversationMessages: The message history from the chat
    ///   - maxMessages: Maximum number of messages to include from history
    /// - Returns: A configured ChatQuery ready for streaming
    static func buildQuery(
        modelId: String,
        systemPrompt: String,
        rules: String,
        conversationMessages: [Message],
        maxMessages: Int
    ) -> ChatQuery {

        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        // Determine if we should use system role or prepend to user message
        let useSystemRole = modelId.hasPrefix("llama") ||
                           modelId.hasPrefix("gpt-oss") ||
                           modelId.hasPrefix("qwen")

        // Add system message/instructions based on model requirements
        // Most models (including unknown ones) prepend to first user message for safety
        if useSystemRole {
            addSystemInstructions(
                to: &messages,
                modelId: modelId,
                systemPrompt: systemPrompt,
                rules: rules
            )
        }

        // Add conversation history
        let recentMessages = Array(conversationMessages.suffix(maxMessages))
        for (index, msg) in recentMessages.enumerated() {
            if msg.role == .user {
                var userContent = msg.content

                // For models that don't use system role: prepend system instructions to the FIRST user message only
                if !useSystemRole && index == 0 {
                    let instructions = rules.isEmpty ? systemPrompt : systemPrompt + "\n\n" + rules
                    userContent = instructions + "\n\n" + msg.content
                }

                messages.append(.user(.init(content: .string(userContent))))
            } else if !msg.content.isEmpty {
                messages.append(.assistant(.init(content: .textContent(msg.content))))
            }
        }

        return ChatQuery(
            messages: messages,
            model: modelId,
            stream: true
        )
    }

    /// Add system instructions to messages array based on model requirements
    private static func addSystemInstructions(
        to messages: inout [ChatQuery.ChatCompletionMessageParam],
        modelId: String,
        systemPrompt: String,
        rules: String
    ) {
        let fullPrompt = rules.isEmpty ? systemPrompt : systemPrompt + "\n" + rules

        switch true {
        case modelId.hasPrefix("deepseek"):
            // DeepSeek-R1 was NOT trained to use system prompts and adding them degrades performance
            // Best practice: Include all instructions in the first user message instead
            // Handled in buildQuery() by prepending to first user message
            break

        case modelId.hasPrefix("mistral"):
            // Mistral models (including Mixtral variants) do not have dedicated system tokens
            // They use [INST] format and concatenate system prompt with first user message
            // Handled in buildQuery() by prepending to first user message
            break

        case modelId.hasPrefix("llama"):
            // Llama models (llama-free, llama3-3-70b) support system prompts
            // Use standard system message format
            messages.append(.system(.init(content: .textContent(fullPrompt))))

        case modelId.hasPrefix("gpt-oss"):
            // GPT-OSS models support system prompts in standard format
            messages.append(.system(.init(content: .textContent(fullPrompt))))

        case modelId.hasPrefix("qwen"):
            // Qwen models support system prompts using ChatML template format
            messages.append(.system(.init(content: .textContent(fullPrompt))))

        default:
            // Default fallback: prepend to first user message (safer for unknown models)
            // This case should rarely be hit since useSystemRole checks cover known models
            break
        }
    }
}
