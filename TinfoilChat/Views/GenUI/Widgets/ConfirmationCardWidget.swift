//
//  ConfirmationCardWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct ConfirmationCardWidget: GenUIWidget {
    struct Detail: Decodable {
        let label: String
        let value: String
    }

    struct Args: Decodable {
        let title: String
        let summary: String?
        let details: [Detail]?
        let confirmLabel: String?
        let cancelLabel: String?
        let confirmResponse: String?
        let cancelResponse: String?
    }

    let name = "confirmation_card"
    let description = "Confirm a consequential action with the user before proceeding. Replaces the chat input with Confirm/Cancel buttons."
    let promptHint = "an explicit Confirm/Cancel prompt that replaces the chat input before consequential actions"

    var schema: JSONSchema {
        let detail = GenUISchema.object(
            properties: [
                "label": GenUISchema.string(),
                "value": GenUISchema.string(),
            ],
            required: ["label", "value"]
        )
        return GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "summary": GenUISchema.string(),
                "details": GenUISchema.array(items: detail),
                "confirmLabel": GenUISchema.string(),
                "cancelLabel": GenUISchema.string(),
                "confirmResponse": GenUISchema.string(),
                "cancelResponse": GenUISchema.string(),
            ],
            required: ["title"]
        )
    }

    var surface: GenUIWidgetSurface { .input }

    @MainActor
    func renderInputArea(args: Args, context: GenUIInputContext) -> AnyView? {
        AnyView(ConfirmationCardView(args: args, context: context))
    }

    @MainActor
    func renderResolved(args: Args, resolution: GenUIResolution, context: GenUIRenderContext) -> AnyView? {
        let isConfirmed: Bool = {
            if case .object(let dict) = resolution.data ?? .null,
               case .string(let decision) = dict["decision"] ?? .null {
                return decision == "confirmed"
            }
            return false
        }()
        return AnyView(
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isConfirmed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isConfirmed ? .green : GenUIStyle.mutedText(context.isDarkMode))
                VStack(alignment: .leading, spacing: 2) {
                    Text(args.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                    Text(isConfirmed ? "Confirmed" : "Cancelled")
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(context.isDarkMode))
                }
                Spacer(minLength: 0)
            }
            .genUICard(isDarkMode: context.isDarkMode, padding: 12)
        )
    }
}

private struct ConfirmationCardView: View {
    let args: ConfirmationCardWidget.Args
    let context: GenUIInputContext

    private var confirmLabel: String { args.confirmLabel ?? "Confirm" }
    private var cancelLabel: String { args.cancelLabel ?? "Cancel" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(args.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                if let summary = args.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(context.isDarkMode))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let details = args.details, !details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(detail.label.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.5)
                                .foregroundColor(GenUIStyle.mutedText(context.isDarkMode))
                                .frame(width: 90, alignment: .leading)
                            Text(detail.value)
                                .font(.caption)
                                .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: confirm) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.caption)
                        Text(confirmLabel).font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(GenUIStyle.primaryText(context.isDarkMode))
                    .foregroundColor(context.isDarkMode ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button(action: cancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark").font(.caption)
                        Text(cancelLabel).font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundColor(GenUIStyle.primaryText(context.isDarkMode))
                    .background(GenUIStyle.subtleBackground(context.isDarkMode))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(GenUIStyle.borderColor(context.isDarkMode), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private func confirm() {
        let response = args.confirmResponse ?? "Confirm"
        context.resolve(response, .object(["decision": .string("confirmed")]))
    }

    private func cancel() {
        let response = args.cancelResponse ?? "Cancel"
        context.resolve(response, .object(["decision": .string("cancelled")]))
    }
}
