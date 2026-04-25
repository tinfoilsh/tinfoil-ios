//
//  AskUserInputWidget.swift
//  TinfoilChat
//
//  Input-surface widget. Replaces the message input area with a multiple
//  choice prompt; the user's selection is submitted as a synthetic user
//  message.

import OpenAI
import SwiftUI

struct AskUserInputWidget: GenUIWidget {
    struct Option: Decodable {
        let id: String?
        let label: String
        let value: String?
        let description: String?
    }

    struct Args: Decodable {
        let question: String
        let options: [Option]
        let helpText: String?
    }

    let name = "ask_user_input"
    let description = "Ask the user a multiple-choice question. Replaces the chat input with a set of clickable options. Use when you need a structured choice before continuing."
    let promptHint = "a multiple-choice question that replaces the chat input with clickable options"

    var schema: JSONSchema {
        let option = GenUISchema.object(
            properties: [
                "id": GenUISchema.string(),
                "label": GenUISchema.string(),
                "value": GenUISchema.string(),
                "description": GenUISchema.string(),
            ],
            required: ["label"]
        )
        return GenUISchema.object(
            properties: [
                "question": GenUISchema.string(description: "The question presented to the user."),
                "options": GenUISchema.array(items: option, description: "2–6 mutually exclusive options.", minItems: 2),
                "helpText": GenUISchema.string(),
            ],
            required: ["question", "options"]
        )
    }

    var surface: GenUIWidgetSurface { .input }

    @MainActor
    func renderInputArea(args: Args, context: GenUIInputContext) -> AnyView? {
        AnyView(AskUserInputView(args: args, context: context))
    }

    @MainActor
    func renderResolved(args: Args, resolution: GenUIResolution, context: GenUIRenderContext) -> AnyView? {
        AnyView(
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(args.question)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                    Text(resolution.text)
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(context.isDarkMode))
                }
                Spacer(minLength: 0)
            }
            .genUICard(isDarkMode: context.isDarkMode, padding: 12)
        )
    }
}

private struct AskUserInputView: View {
    let args: AskUserInputWidget.Args
    let context: GenUIInputContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(args.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                if let helpText = args.helpText, !helpText.isEmpty {
                    Text(helpText)
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(context.isDarkMode))
                }
            }

            FlowOptions(spacing: 6) {
                ForEach(Array(args.options.enumerated()), id: \.offset) { _, option in
                    Button(action: { resolve(option) }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.subheadline.weight(.medium))
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundColor(GenUIStyle.mutedText(context.isDarkMode))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(GenUIStyle.subtleBackground(context.isDarkMode))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(GenUIStyle.borderColor(context.isDarkMode), lineWidth: 1)
                        )
                        .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    private func resolve(_ option: AskUserInputWidget.Option) {
        let value = option.value ?? option.label
        let payload: JSONValue = .object([
            "choice": .string(value),
            "label": .string(option.label),
        ])
        context.resolve(value, payload)
    }
}

/// Lightweight wrapping HStack used by the options list. Mirrors the
/// behavior of the recipe-tag flow layout but is parameterized on a
/// generic content closure.
private struct FlowOptions<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        // SwiftUI's `Layout` requires concrete subviews. We use a simple
        // wrapping HStack via a flex container that lets the inner ViewBuilder
        // expand. For 2–6 options this stays on one line on most devices and
        // wraps gracefully on narrow widths.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing, content: content)
            VStack(alignment: .leading, spacing: spacing, content: content)
        }
    }
}
