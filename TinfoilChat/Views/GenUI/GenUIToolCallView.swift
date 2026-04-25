//
//  GenUIToolCallView.swift
//  TinfoilChat
//
//  Renders a single GenUI tool call inline in the chat. Mirrors the
//  webapp's `GenUIToolCallRenderer`: while streaming, shows a tracer
//  placeholder; once the JSON arguments fully parse, swaps in the real
//  widget. Input-surface widgets render through `GenUIInputAreaView`
//  inside `MessageInputView` and produce a compact stamp here once
//  resolved.

import SwiftUI

struct GenUIToolCallView: View {
    let toolCall: GenUIToolCall
    let isStreaming: Bool
    let isDarkMode: Bool
    let resolution: GenUIResolution?
    let onRetry: (() -> Void)?

    var body: some View {
        let widget = GenUIRegistry.shared.widget(named: toolCall.name)
        let parsed = parsedArgs()
        let context = GenUIRenderContext(isDarkMode: isDarkMode)

        // Input-surface widgets only show inline once they've been
        // resolved; the live UI lives in the input area.
        if widget?.surface == .input {
            if let widget, let resolution, let data = parsed,
               let resolvedView = widget.renderResolved(
                rawArgs: data,
                resolution: resolution,
                context: context
               ) {
                return AnyView(resolvedView)
            }
            return AnyView(EmptyView())
        }

        if isStreaming {
            return AnyView(streamingPlaceholder)
        }

        if let widget, let data = parsed,
           let rendered = widget.renderInline(rawArgs: data, context: context) {
            return AnyView(rendered)
        }

        return AnyView(parseFailureCard)
    }

    private func parsedArgs() -> Data? {
        guard !toolCall.arguments.isEmpty else { return nil }
        guard let data = toolCall.arguments.data(using: .utf8) else { return nil }
        // Validate it is at least a JSON object before handing to the widget.
        guard let json = try? JSONSerialization.jsonObject(with: data),
              json is [String: Any] else { return nil }
        return data
    }

    @ViewBuilder
    private var streamingPlaceholder: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(GenUIStyle.primaryText(isDarkMode))
                .frame(width: 8, height: 8)
                .opacity(0.7)
            Text("Generating component")
                .font(.subheadline.weight(.medium))
                .foregroundColor(GenUIStyle.primaryText(isDarkMode))
            ProgressView().scaleEffect(0.7)
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
                .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var parseFailureCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't produce a valid widget")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                Text("The model returned a response that didn't match the \(toolCall.name) widget schema.")
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.caption)
                        Text("Try again").font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .genUICard(isDarkMode: isDarkMode, padding: 12)
    }
}
