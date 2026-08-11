//
//  GenUIToolCallView.swift
//  TinfoilChat
//
//  Renders a single GenUI tool call inline in the chat. Mirrors the
//  webapp's `GenUIToolCallRenderer`: while streaming, shows a tracer
//  placeholder; once the assistant turn completes, swaps in the real
//  widget. Input-surface widgets render through `GenUIInputAreaView`
//  inside `MessageInputView` and produce a compact stamp here once
//  resolved.

import SwiftUI

enum GenUIToolCallPresentation {
    static func showsPlaceholder(arguments: String, isRenderingStream: Bool) -> Bool {
        guard isRenderingStream,
              let data = arguments.data(using: .utf8) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) == nil
    }
}

struct GenUIToolCallView: View {
    let toolCall: GenUIToolCall
    let isStreaming: Bool
    let isDarkMode: Bool
    let resolution: GenUIResolution?
    let retryState: GenUIRetryState?
    let onRetry: (() -> Void)?

    var body: some View {
        let widget = GenUIRegistry.shared.widget(named: toolCall.name)
        let parsed = parsedArgs(widget: widget)
        let context = GenUIRenderContext(isDarkMode: isDarkMode)

        if isStreaming || retryState == .generating {
            return AnyView(streamingPlaceholder)
        }

        // Input-surface widgets only show inline once they've been
        // resolved; the live UI lives in the input area.
        if widget?.surface == .input {
            if let widget, let resolution, case .valid(let data) = parsed,
               let resolvedView = widget.renderResolved(
                rawArgs: data,
                resolution: resolution,
                context: context
               ) {
                return AnyView(resolvedView)
            }
            if case .invalid = parsed, widget != nil {
                return AnyView(parseFailureCard(parsedArgs: parsed))
            }
            return AnyView(EmptyView())
        }

        if let widget, case .valid(let data) = parsed,
           let rendered = widget.renderInline(rawArgs: data, context: context) {
            return AnyView(rendered)
        }

        // When the widget itself isn't registered on this client (e.g. a
        // tool call recorded before the widget was added or after it was
        // removed) defer to `UnsupportedGenUINoticeView`, which is rendered
        // once per message at the bubble level.
        if widget == nil {
            return AnyView(EmptyView())
        }

        return AnyView(parseFailureCard(parsedArgs: parsed))
    }

    private enum ParsedArgs {
        case valid(Data)
        case invalid(GenUIArgumentValidationError)
    }

    private func parsedArgs(widget: AnyGenUIWidget?) -> ParsedArgs {
        guard let data = toolCall.arguments.data(using: .utf8),
              let widget else {
            return .invalid(.invalidJSONObject)
        }
        if let error = GenUIArgumentValidator.validationError(rawArgs: data, widget: widget) {
            return .invalid(error)
        }
        return .valid(data)
    }

    private func displayedError(parsedArgs: ParsedArgs) -> GenUIArgumentValidationError {
        if case .invalid(let error) = parsedArgs {
            return error
        }
        return .widgetDecoding(codingPath: "$")
    }

    private var failureTitle: String {
        switch retryState {
        case .requestFailed:
            return "Couldn't retry this widget"
        case .invalidOutput:
            return "The retry didn't return a valid widget"
        case .staleOrigin:
            return "This widget changed before retry completed"
        case .generating, .none:
            return "Couldn't display this widget"
        }
    }

    private func failureDetail(parsedArgs: ParsedArgs) -> String {
        switch retryState {
        case .requestFailed:
            return "The retry request failed. Try again."
        case .staleOrigin:
            return "Reload the conversation and try again from the latest version."
        case .generating:
            return "Generating component"
        case .invalidOutput, .none:
            if case .invalidOutput(let outputError) = retryState {
                switch outputError {
                case .invalidArguments(let validationError):
                    return validationDetail(validationError)
                case .incompleteResponse:
                    return "The model stopped before returning a complete widget. Try again."
                case .refusal:
                    return "The model declined to regenerate this widget. Try again."
                }
            }
            return validationDetail(displayedError(parsedArgs: parsedArgs))
        }
    }

    private func validationDetail(_ error: GenUIArgumentValidationError) -> String {
        switch error {
        case .invalidJSONObject:
            return "The response wasn't a valid JSON object."
        case .widgetDecoding(let codingPath):
            return "The response didn't match the \(toolCall.name) widget's expected shape at \(codingPath)."
        }
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
    private func parseFailureCard(parsedArgs: ParsedArgs) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(failureTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                Text(failureDetail(parsedArgs: parsedArgs))
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
