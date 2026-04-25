//
//  GenUIInputAreaView.swift
//  TinfoilChat
//
//  Mounts an input-surface widget inside `MessageInputView`. The wrapper
//  owns the resolve/cancel plumbing so individual widgets only deal with
//  their own UI.

import Foundation
import SwiftUI

/// Pending input-surface tool call descriptor. Mirrors the webapp's
/// `PendingInputToolCall` selector logic.
struct PendingInputToolCall: Equatable {
    let messageIndex: Int
    let toolCallId: String
    let name: String
    let arguments: String
}

extension Message {
    /// Resolution map persisted alongside `toolCalls`. Returns the
    /// resolution for the given tool-call id, if any.
    func genUIResolution(for toolCallId: String) -> GenUIResolution? {
        genUIResolutions[toolCallId]
    }
}

extension Chat {
    /// The single pending input-surface tool call on the most recent
    /// assistant message, or `nil` when no widget is awaiting input.
    @MainActor
    func pendingInputToolCall() -> PendingInputToolCall? {
        for index in messages.indices.reversed() {
            let message = messages[index]
            guard message.role == .assistant else { continue }
            // Walk the tool calls in reverse to surface the most-recent one.
            for toolCall in message.toolCalls.reversed() {
                guard let widget = GenUIRegistry.shared.widget(named: toolCall.name),
                      widget.surface == .input else { continue }
                if message.genUIResolution(for: toolCall.id) != nil { continue }
                guard let data = toolCall.arguments.data(using: .utf8),
                      widget.canRender(rawArgs: data) else { continue }
                return PendingInputToolCall(
                    messageIndex: index,
                    toolCallId: toolCall.id,
                    name: toolCall.name,
                    arguments: toolCall.arguments
                )
            }
            // Only the latest assistant message is considered.
            return nil
        }
        return nil
    }
}

@MainActor
struct GenUIInputAreaView: View {
    let pending: PendingInputToolCall
    let isDarkMode: Bool
    let onResolve: (_ toolCallId: String, _ resultText: String, _ resultData: JSONValue?) -> Void
    let onCancel: ((String) -> Void)?

    var body: some View {
        let widget = GenUIRegistry.shared.widget(named: pending.name)
        let context = GenUIInputContext(
            toolCallId: pending.toolCallId,
            isDarkMode: isDarkMode,
            resolve: { resultText, resultData in
                onResolve(pending.toolCallId, resultText, resultData)
            },
            cancel: onCancel.map { handler in { handler(pending.toolCallId) } }
        )
        let data = pending.arguments.data(using: .utf8) ?? Data()

        if let widget, let view = widget.renderInputArea(rawArgs: data, context: context) {
            view
        } else {
            Text("Unable to render component: \(pending.name)")
                .font(.caption)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                .padding(.vertical, 8)
        }
    }
}
