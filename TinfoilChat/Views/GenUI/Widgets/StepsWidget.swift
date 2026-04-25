//
//  StepsWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct StepsWidget: GenUIWidget {
    struct Step: Decodable {
        let title: String
        let description: String?
        let status: String?
    }

    struct Args: Decodable {
        let steps: [Step]
    }

    let name = "render_steps"
    let description = "Show an ordered list of steps or a checklist. Use for processes, instructions, or progress tracking."
    let promptHint = "ordered steps, instructions, or checklist"

    var schema: JSONSchema {
        let stepSchema = GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "description": GenUISchema.string(),
                "status": GenUISchema.string(enumValues: ["pending", "active", "complete"]),
            ],
            required: ["title"]
        )
        return GenUISchema.object(
            properties: [
                "steps": GenUISchema.array(
                    items: stepSchema,
                    description: "Ordered steps to display",
                    minItems: 1
                ),
            ],
            required: ["steps"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(StepsView(steps: args.steps, isDarkMode: context.isDarkMode))
    }
}

private struct StepsView: View {
    let steps: [StepsWidget.Step]
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 10) {
                    statusIcon(for: step.status)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(
                                step.status == "complete"
                                    ? GenUIStyle.mutedText(isDarkMode)
                                    : GenUIStyle.primaryText(isDarkMode)
                            )
                            .strikethrough(step.status == "complete")
                        if let description = step.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: String?) -> some View {
        switch status {
        case "complete":
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case "active":
            Image(systemName: "circle.inset.filled").foregroundColor(GenUIStyle.accent)
        default:
            Image(systemName: "circle").foregroundColor(GenUIStyle.mutedText(isDarkMode))
        }
    }
}
