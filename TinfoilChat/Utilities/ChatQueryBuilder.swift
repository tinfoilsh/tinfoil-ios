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
    @MainActor
    static func buildQuery(
        modelId: String,
        systemPrompt: String,
        rules: String,
        conversationMessages: [Message],
        maxMessages: Int,
        stream: Bool = true,
        webSearchEnabled: Bool = false,
        isMultimodal: Bool = false,
        genUIEnabled: Bool = true
    ) -> ChatQuery {

        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        // Most models support system role; DeepSeek is the known exception
        let useSystemRole = !modelId.hasPrefix("deepseek")

        // Append the GenUI prompt hint so the model knows it can call
        // render_* tools instead of replying with markdown for structured
        // content. The hint is appended to the system prompt regardless
        // of which transport carries the system instructions (system role
        // vs synthetic <system> user message).
        var effectiveSystemPrompt = systemPrompt
        if genUIEnabled {
            let hint = GenUIRegistry.shared.buildPromptHint()
            effectiveSystemPrompt = systemPrompt.isEmpty ? hint : systemPrompt + "\n\n" + hint
        }

        if useSystemRole {
            let fullPrompt = rules.isEmpty ? effectiveSystemPrompt : effectiveSystemPrompt + "\n\n" + rules
            messages.append(.system(.init(content: .textContent(fullPrompt))))
        }

        // Add conversation history
        let recentMessages = Array(conversationMessages.suffix(maxMessages))
        var hasAddedSystemInstructions = useSystemRole

        for msg in recentMessages {
            if msg.role == .user {
                var userContent = msg.content

                // For models that don't use system role (e.g. DeepSeek): inject system instructions as a separate user message
                if !hasAddedSystemInstructions {
                    let rawInstructions = rules.isEmpty ? effectiveSystemPrompt : effectiveSystemPrompt + "\n\n" + rules
                    let systemContent = "<system>\n\(rawInstructions)\n</system>"
                    messages.append(.user(.init(content: .string(systemContent))))
                    hasAddedSystemInstructions = true
                }

                // Derive document content and image data from attachments
                let documentAttachments = msg.attachments.filter { $0.type == .document }
                let imageAttachments = msg.attachments.filter { $0.type == .image }

                // Prepend document content as context when present
                if !documentAttachments.isEmpty {
                    let docContent = documentAttachments
                        .compactMap { attachment -> String? in
                            guard let text = attachment.textContent, !text.isEmpty else { return nil }
                            return "Document title: \(attachment.fileName)\nDocument contents:\n\(text)"
                        }
                        .joined(separator: "\n\n")
                    if !docContent.isEmpty {
                        userContent = "---\nDocument content:\n\(docContent)\n---\n\n\(userContent)"
                    }
                }

                // Use multimodal content parts when model supports it and message has images
                if isMultimodal, !imageAttachments.isEmpty {
                    var parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = []
                    parts.append(.text(.init(text: userContent)))
                    for attachment in imageAttachments {
                        guard let base64 = attachment.base64,
                              let mimeType = attachment.mimeType else { continue }
                        let imageUrl = ChatQuery.ChatCompletionMessageParam.ContentPartImageParam.ImageURL(
                            url: "data:\(mimeType);base64,\(base64)",
                            detail: .auto
                        )
                        parts.append(.image(.init(imageUrl: imageUrl)))
                    }
                    messages.append(.user(.init(content: .contentParts(parts))))
                } else if !imageAttachments.isEmpty {
                    // Non-multimodal model: append image descriptions as text fallback
                    let descriptions = imageAttachments
                        .compactMap { attachment -> String? in
                            guard let desc = attachment.description, !desc.isEmpty else { return nil }
                            return "Image: \(attachment.fileName)\nDescription:\n\(desc)"
                        }
                    if !descriptions.isEmpty {
                        let descText = descriptions.joined(separator: "\n\n")
                        userContent = userContent + "\n\n[Treat these descriptions as if they are the raw images.]\n" + descText
                    }
                    messages.append(.user(.init(content: .string(userContent))))
                } else {
                    messages.append(.user(.init(content: .string(userContent))))
                }
            } else if !msg.content.isEmpty || !msg.toolCalls.isEmpty {
                // Emit `tool_calls` on the assistant message so the model
                // sees its previously-rendered widgets, then synthesize
                // `role: 'tool'` results so the API's tool-call/tool-result
                // pairing rule is satisfied. GenUI tools are display-only
                // (the client rendered the component); we acknowledge with
                // a constant payload that mirrors the webapp.
                let toolCallParams: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]? = msg.toolCalls.isEmpty
                    ? nil
                    : msg.toolCalls.map { tc in
                        .init(
                            id: tc.id,
                            function: .init(
                                arguments: tc.arguments.isEmpty ? "{}" : tc.arguments,
                                name: tc.name
                            )
                        )
                    }
                let assistantContent: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent? =
                    msg.content.isEmpty && toolCallParams != nil
                        ? nil
                        : .textContent(msg.content)
                messages.append(.assistant(.init(
                    content: assistantContent,
                    toolCalls: toolCallParams
                )))
                if let toolCallParams {
                    for param in toolCallParams {
                        messages.append(.tool(.init(
                            content: .textContent("displayed"),
                            toolCallId: param.id
                        )))
                    }
                }
            }
        }

        let tools: [ChatQuery.ChatCompletionToolParam]? = genUIEnabled
            ? GenUIRegistry.shared.buildToolParams()
            : nil

        return ChatQuery(
            messages: messages,
            model: modelId,
            tools: tools,
            webSearchOptions: webSearchEnabled ? .init() : nil,
            stream: stream
        )
    }

}
