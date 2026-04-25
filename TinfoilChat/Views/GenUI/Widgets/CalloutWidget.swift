//
//  CalloutWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct CalloutWidget: GenUIWidget {
    struct Args: Decodable {
        let variant: String?
        let title: String?
        let content: String
    }

    let name = "render_callout"
    let description = "Display a highlighted callout box for key takeaways, warnings, tips, or notes."
    let promptHint = "highlighted callout for takeaways, warnings, tips, or notes"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "variant": GenUISchema.string(
                    description: "Visual style (defaults to info)",
                    enumValues: ["info", "success", "warning", "error", "tip"]
                ),
                "title": GenUISchema.string(),
                "content": GenUISchema.string(description: "Callout body text"),
            ],
            required: ["content"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(CalloutView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct CalloutView: View {
    let args: CalloutWidget.Args
    let isDarkMode: Bool

    private var config: (icon: String, tint: Color) {
        switch args.variant {
        case "success": return ("checkmark.circle.fill", .green)
        case "warning": return ("exclamationmark.triangle.fill", .yellow)
        case "error":   return ("xmark.octagon.fill", .red)
        case "tip":     return ("lightbulb.fill", .purple)
        default:        return ("info.circle.fill", .blue)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: config.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(config.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if let title = args.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
                Text(args.content)
                    .font(.subheadline)
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                .fill(config.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                .stroke(config.tint.opacity(0.30), lineWidth: 1)
        )
    }
}
