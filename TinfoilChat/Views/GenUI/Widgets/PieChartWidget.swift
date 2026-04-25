//
//  PieChartWidget.swift
//  TinfoilChat
//

import Charts
import OpenAI
import SwiftUI

struct PieChartWidget: GenUIWidget {
    struct Args: Decodable {
        let data: [ChartRow]
        let nameKey: String?
        let valueKey: String?
        let title: String?
    }

    let name = "render_pie_chart"
    let description = "Render a pie chart for proportional data. Use when showing how parts make up a whole."
    let promptHint = "parts of a whole as a pie chart"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "data": GenUISchema.array(
                    items: GenUISchema.object(properties: [:]),
                    description: "Slices as [{\"name\":\"A\",\"value\":10}, ...]",
                    minItems: 1
                ),
                "nameKey": GenUISchema.string(),
                "valueKey": GenUISchema.string(),
                "title": GenUISchema.string(),
            ],
            required: ["data"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(PieChartView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct PieChartView: View {
    let args: PieChartWidget.Args
    let isDarkMode: Bool

    private struct Slice: Identifiable {
        let id: Int
        let name: String
        let value: Double
    }

    var body: some View {
        let keys = inferChartKeys(args.data, preferredX: args.nameKey, preferredY: args.valueKey)
        let slices: [Slice] = args.data
            .enumerated()
            .compactMap { index, row in
                guard let name = row.string(keys.x) ?? row.string(row.allKeys.first ?? "") else { return nil }
                guard let value = row.double(keys.y), value > 0 else { return nil }
                return Slice(id: index, name: name, value: value)
            }
        let total = slices.reduce(0) { $0 + $1.value }

        VStack(alignment: .leading, spacing: 8) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            HStack(alignment: .center, spacing: 12) {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value(keys.y, slice.value),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(GenUIStyle.paletteColor(slice.id))
                    .cornerRadius(2)
                }
                .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices) { slice in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(GenUIStyle.paletteColor(slice.id))
                                .frame(width: 8, height: 8)
                            Text(slice.name)
                                .font(.caption)
                                .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(percentLabel(slice.value, total: total))
                                .font(.caption.weight(.medium))
                                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        }
                    }
                }
            }
        }
        .genUICard(isDarkMode: isDarkMode)
    }

    private func percentLabel(_ value: Double, total: Double) -> String {
        guard total > 0 else { return "0%" }
        let pct = Int(((value / total) * 100).rounded())
        return "\(pct)%"
    }
}
