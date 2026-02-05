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
/// **System Prompt Handling:**
/// Most modern models support system role in messages array.
/// For models that don't support it, we prepend to the first user message.
struct ChatQueryBuilder {

    /// Build ChatQuery with model-appropriate system prompt and rules injection
    /// - Parameters:
    ///   - modelId: The model identifier
    ///   - systemPrompt: The base system prompt with placeholders already replaced
    ///   - rules: Additional rules to include (will be combined with system prompt based on model)
    ///   - conversationMessages: The message history from the chat
    ///   - maxMessages: Maximum number of messages to include from history
    ///   - stream: Whether to stream the response (default: true)
    ///   - webSearchEnabled: Whether to enable web search for this query (default: false)
    ///   - isMultimodal: Whether the current model supports image content parts
    /// - Returns: A configured ChatQuery
    static func buildQuery(
        modelId: String,
        systemPrompt: String,
        rules: String,
        conversationMessages: [Message],
        maxMessages: Int,
        stream: Bool = true,
        webSearchEnabled: Bool = false,
        isMultimodal: Bool = false
    ) -> ChatQuery {

        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        // Always use system role - all models we support handle it properly
        // This is the standard OpenAI API format
        let useSystemRole = true

        // Add system message
        if useSystemRole {
            let fullPrompt = rules.isEmpty ? systemPrompt : systemPrompt + "\n\n" + rules
            messages.append(.system(.init(content: .textContent(fullPrompt))))
        }

        // Add conversation history
        let recentMessages = Array(conversationMessages.suffix(maxMessages))
        var hasAddedSystemInstructions = useSystemRole

        for msg in recentMessages {
            if msg.role == .user {
                var userContent = msg.content

                // For models that don't use system role: prepend system instructions to the FIRST user message
                if !hasAddedSystemInstructions {
                    let instructions = rules.isEmpty ? systemPrompt : systemPrompt + "\n\n" + rules
                    userContent = instructions + "\n\n" + msg.content
                    hasAddedSystemInstructions = true
                }

                // Prepend document content as context when present
                if let docContent = msg.documentContent, !docContent.isEmpty {
                    userContent = "---\nDocument content:\n\(docContent)\n---\n\n\(userContent)"
                }

                // Use multimodal content parts when model supports it and message has an image
                if isMultimodal, let imageBase64 = msg.imageBase64, !imageBase64.isEmpty {
                    var parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = []
                    parts.append(.text(.init(text: userContent)))
                    let imageUrl = ContentPartImageParam.ImageURL(
                        url: "data:image/jpeg;base64,\(imageBase64)",
                        detail: .auto
                    )
                    parts.append(.image(.init(imageUrl: imageUrl)))
                    messages.append(.user(.init(content: .contentParts(parts))))
                } else {
                    messages.append(.user(.init(content: .string(userContent))))
                }
            } else if !msg.content.isEmpty {
                messages.append(.assistant(.init(content: .textContent(msg.content))))
            }
        }

        return ChatQuery(
            messages: messages,
            model: modelId,
            webSearchOptions: webSearchEnabled ? .init() : nil,
            stream: stream
        )
    }

}
