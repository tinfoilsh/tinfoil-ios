//
//  StatCardsWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct StatCardsWidget: GenUIWidget {
    struct Stat: Decodable {
        let label: String
        let value: StringOrNumber
        let trend: String?
    }

    struct Args: Decodable {
        let stats: [Stat]
    }

    let name = "render_stat_cards"
    let description = "Display a grid of metrics or KPIs. Use when presenting multiple numeric summaries."
    let promptHint = "grid of numeric KPIs or metrics"

    var schema: JSONSchema {
        let statSchema = GenUISchema.object(
            properties: [
                "label": GenUISchema.string(),
                "value": GenUISchema.stringOrNumber(),
                "trend": GenUISchema.string(enumValues: ["up", "down"]),
            ],
            required: ["label", "value"]
        )
        return GenUISchema.object(
            properties: [
                "stats": GenUISchema.array(
                    items: statSchema,
                    description: "Metrics or KPIs to display in a responsive grid",
                    minItems: 1
                ),
            ],
            required: ["stats"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(StatCardsView(stats: args.stats, isDarkMode: context.isDarkMode))
    }
}

private struct StatCardsView: View {
    let stats: [StatCardsWidget.Stat]
    let isDarkMode: Bool

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                VStack(alignment: .leading, spacing: 6) {
                    Text(stat.label)
                        .font(.caption.weight(.medium))
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(stat.value.stringValue)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        if stat.trend == "up" {
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.green)
                        } else if stat.trend == "down" {
                            Image(systemName: "arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.red)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .genUICard(isDarkMode: isDarkMode, padding: 12)
            }
        }
    }
}
