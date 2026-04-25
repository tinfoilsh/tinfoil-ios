//
//  LineChartWidget.swift
//  TinfoilChat
//

import Charts
import OpenAI
import SwiftUI

struct LineChartWidget: GenUIWidget {
    struct Args: Decodable {
        let data: [ChartRow]
        let xKey: String?
        let yKey: String?
        let title: String?
        let color: String?
    }

    let name = "render_line_chart"
    let description = "Render a line chart for trends over time. Use when showing how values change across a sequence."
    let promptHint = "trends or sequences as a line chart"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "data": GenUISchema.array(
                    items: GenUISchema.openObjectOfStringOrNumber(),
                    description: "Data points sharing the same keys",
                    minItems: 1
                ),
                "xKey": GenUISchema.string(),
                "yKey": GenUISchema.string(),
                "title": GenUISchema.string(),
                "color": GenUISchema.string(),
            ],
            required: ["data"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(LineChartView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct LineChartView: View {
    let args: LineChartWidget.Args
    let isDarkMode: Bool

    var body: some View {
        let keys = inferChartKeys(args.data, preferredX: args.xKey, preferredY: args.yKey)
        let color = parseHex(args.color) ?? GenUIStyle.accent
        let entries: [(label: String, value: Double, id: Int)] = args.data
            .enumerated()
            .compactMap { index, row in
                guard let label = row.string(keys.x) ?? row.string(row.allKeys.first ?? "") else { return nil }
                guard let value = row.double(keys.y) else { return nil }
                return (label, value, index)
            }

        VStack(alignment: .leading, spacing: 8) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            Chart(entries, id: \.id) { entry in
                LineMark(
                    x: .value(keys.x, entry.label),
                    y: .value(keys.y, entry.value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value(keys.x, entry.label),
                    y: .value(keys.y, entry.value)
                )
                .foregroundStyle(color)
                .symbolSize(40)
            }
            .frame(height: GenUIStyle.chartHeight)
        }
        .genUICard(isDarkMode: isDarkMode)
    }
}
