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

    /// Endpoint key for the chat completions API; matches the controlplane
    /// `reasoningConfig.params` keying.
    static let chatCompletionsEndpoint = "/v1/chat/completions"

    /// Placeholder substituted with the user-selected reasoning effort when
    /// expanding `reasoningConfig.params[endpoint].enable`. Mirrors the
    /// webapp's `EFFORT_PLACEHOLDER`.
    static let effortPlaceholder = "$EFFORT"

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
    ///   - reasoningConfig: Optional per-model reasoning configuration. When
    ///     present, the matching enable/disable block from
    ///     `params[chatCompletionsEndpoint]` is merged into the request body
    ///     via `extraBody`, with `$EFFORT` substituted using `reasoningEffort`
    ///     (translated through `effortMap` when provided).
    ///   - reasoningEffort: User-selected effort tier for models that expose
    ///     graded effort. Ignored for models that do not.
    ///   - thinkingEnabled: Whether thinking is on for models that support a
    ///     toggle. Ignored for models that do not.
    /// - Returns: A configured ChatQuery
    static func buildQuery(
        modelId: String,
        systemPrompt: String,
        rules: String,
        conversationMessages: [Message],
        maxMessages: Int,
        stream: Bool = true,
        webSearchEnabled: Bool = false,
        isMultimodal: Bool = false,
        reasoningConfig: ReasoningConfig? = nil,
        reasoningEffort: ReasoningEffort = .medium,
        thinkingEnabled: Bool = true
    ) -> ChatQuery {

        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        // Most models support system role; DeepSeek is the known exception
        let useSystemRole = !modelId.hasPrefix("deepseek")

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

                // For models that don't use system role (e.g. DeepSeek): inject system instructions as a separate user message
                if !hasAddedSystemInstructions {
                    let rawInstructions = rules.isEmpty ? systemPrompt : systemPrompt + "\n\n" + rules
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
            } else if !msg.content.isEmpty {
                messages.append(.assistant(.init(content: .textContent(msg.content))))
            }
        }

        let extraBody = makeReasoningExtraBody(
            reasoningConfig: reasoningConfig,
            reasoningEffort: reasoningEffort,
            thinkingEnabled: thinkingEnabled
        )

        return ChatQuery(
            messages: messages,
            model: modelId,
            webSearchOptions: webSearchEnabled ? .init() : nil,
            stream: stream,
            extraBody: extraBody
        )
    }

    /// Build the `extraBody` map to splice into the ChatQuery for a reasoning
    /// model. Returns nil for non-reasoning models or when the config has no
    /// chat-completions params block.
    static func makeReasoningExtraBody(
        reasoningConfig: ReasoningConfig?,
        reasoningEffort: ReasoningEffort,
        thinkingEnabled: Bool
    ) -> [String: OpenAIJSON]? {
        guard let cfg = reasoningConfig else { return nil }
        guard let endpointParams = cfg.params?[chatCompletionsEndpoint] else {
            return nil
        }

        // Pick enable vs disable based on the toggle. Models that don't
        // support a toggle always take the enable block.
        let supportsToggle = cfg.supportsToggle == true
        let rawBlock: OpenAIJSON?
        if supportsToggle {
            rawBlock = thinkingEnabled ? endpointParams.enable : endpointParams.disable
        } else {
            rawBlock = endpointParams.enable
        }
        guard let block = rawBlock else { return nil }

        // Translate the UI effort through `effortMap` when present (e.g.
        // DeepSeek V4 only accepts `high`/`max`). Skipped for models that
        // do not support graded effort, but keeping the substitution
        // unconditional is harmless because the placeholder will simply not
        // appear in the block.
        let supportsEffort = cfg.supportsEffort == true
        let uiEffort = supportsEffort ? reasoningEffort.rawValue : ReasoningEffort.medium.rawValue
        let effort = cfg.effortMap?[uiEffort] ?? uiEffort

        let expanded = substituteEffort(block, effort: effort)
        guard case .object(let dict) = expanded, !dict.isEmpty else { return nil }
        return dict
    }

    /// Recursively clone an `OpenAIJSON`, replacing any string equal to
    /// `effortPlaceholder` with `effort`. Mirrors the webapp's
    /// `substituteEffort` helper.
    private static func substituteEffort(_ value: OpenAIJSON, effort: String) -> OpenAIJSON {
        switch value {
        case .string(let s):
            return s == effortPlaceholder ? .string(effort) : .string(s)
        case .array(let items):
            return .array(items.map { substituteEffort($0, effort: effort) })
        case .object(let dict):
            var out: [String: OpenAIJSON] = [:]
            for (k, v) in dict {
                out[k] = substituteEffort(v, effort: effort)
            }
            return .object(out)
        case .null, .bool, .int, .double:
            return value
        }
    }

}
