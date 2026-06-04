//
//  ChartWidget.swift
//  TinfoilChat
//
//  Unified chart widget. Renders a bar / line / pie chart from tabular
//  data driven by an explicit `type` field, mirroring the webapp's
//  `render_chart` widget.

import Charts
import OpenAI
import SwiftUI

/// A `Decodable` shim that captures arbitrary `[String: String|Number]`
/// dictionaries as `JSONValue` so chart widgets can decode the shape the
/// model emits without locking down property names.
struct ChartRow: Decodable {
    let values: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        if case .object(let dict) = raw {
            self.values = dict
        } else {
            self.values = [:]
        }
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        switch value {
        case .string(let s): return s
        case .number(let n):
            if n.isFinite,
               n >= Double(Int.min),
               n <= Double(Int.max),
               n.truncatingRemainder(dividingBy: 1) == 0 {
                return String(Int(n))
            }
            return String(n)
        default: return nil
        }
    }

    func double(_ key: String) -> Double? {
        guard let value = values[key] else { return nil }
        switch value {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var allKeys: [String] { Array(values.keys) }

    func isString(_ key: String) -> Bool {
        if case .string = values[key] { return true }
        return false
    }

    func isNumber(_ key: String) -> Bool {
        if case .number = values[key] { return true }
        return false
    }
}

/// Picks an x/y key pair, preferring caller hints, then the first
/// string/number columns. Mirrors the webapp's `inferChartKeys`.
func inferChartKeys(_ rows: [ChartRow], preferredX: String?, preferredY: String?) -> (x: String, y: String) {
    let firstKeys = rows.first?.allKeys ?? []
    var allKeys: [String] = []
    var seen: Set<String> = []
    for row in rows {
        for key in row.allKeys where !seen.contains(key) {
            seen.insert(key)
            allKeys.append(key)
        }
    }
    let order = firstKeys + allKeys.filter { !firstKeys.contains($0) }

    var x = preferredX.flatMap { allKeys.contains($0) ? $0 : nil }
    var y = preferredY.flatMap { allKeys.contains($0) ? $0 : nil }
    if x == nil {
        x = order.first(where: { key in rows.contains(where: { $0.isString(key) }) }) ?? order.first
    }
    if y == nil {
        y = order.first(where: { key in
            key != x && rows.contains(where: { $0.isNumber(key) })
        })
    }
    if y == nil {
        y = order.first(where: { $0 != x }) ?? order.first
    }
    return (x ?? "label", y ?? "value")
}

func parseHex(_ hex: String?) -> Color? {
    guard let hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
    var rgba: UInt64 = 0
    guard Scanner(string: cleaned).scanHexInt64(&rgba) else { return nil }
    let r, g, b, a: Double
    if cleaned.count == 8 {
        r = Double((rgba >> 24) & 0xFF) / 255.0
        g = Double((rgba >> 16) & 0xFF) / 255.0
        b = Double((rgba >> 8) & 0xFF) / 255.0
        a = Double(rgba & 0xFF) / 255.0
    } else {
        r = Double((rgba >> 16) & 0xFF) / 255.0
        g = Double((rgba >> 8) & 0xFF) / 255.0
        b = Double(rgba & 0xFF) / 255.0
        a = 1.0
    }
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
}

private let maxVisibleXAxisLabels = 6

private func visibleXAxisLabels(_ labels: [String]) -> [String] {
    guard labels.count > maxVisibleXAxisLabels else { return labels }
    let stride = Int(ceil(Double(labels.count) / Double(maxVisibleXAxisLabels)))
    var selected: [String] = []
    for (index, label) in labels.enumerated() where index % stride == 0 {
        selected.append(label)
    }
    if let last = labels.last, selected.last != last {
        selected.append(last)
    }
    return selected
}

private func compactXAxisLabel(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 10 else { return trimmed }
    return String(trimmed.prefix(9)) + "…"
}

struct ChartWidget: GenUIWidget {
    enum ChartKind: String, Decodable {
        case bar
        case line
        case pie
    }

    struct Args: Decodable {
        let type: ChartKind
        let data: [ChartRow]
        let xKey: String?
        let yKey: String?
        let title: String?
        let color: String?
    }

    let name = "render_chart"
    let description = """
        Render a chart from tabular data. Choose `type`: "bar" for categorical \
        comparisons, "line" for trends or sequences over time, "pie" for \
        proportions / parts of a whole.
        """
    let promptHint = "a chart from tabular data — pass type \"bar\" | \"line\" | \"pie\" depending on whether you are comparing categories, showing a trend, or showing parts of a whole"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "type": GenUISchema.string(
                    description: "Chart type. \"bar\" for categorical comparisons, \"line\" for trends or sequences, \"pie\" for parts of a whole.",
                    enumValues: ["bar", "line", "pie"]
                ),
                "data": GenUISchema.array(
                    items: GenUISchema.openObjectOfStringOrNumber(),
                    description: "Data points sharing the same keys, e.g. [{\"label\":\"A\",\"value\":10}, ...]",
                    minItems: 1
                ),
                "xKey": GenUISchema.string(description: "For bar/line: key for the category axis. For pie: key for slice names."),
                "yKey": GenUISchema.string(description: "For bar/line: key for the numeric axis. For pie: key for slice values."),
                "title": GenUISchema.string(),
                "color": GenUISchema.string(description: "Primary series color hex string (bar/line). Pie slices use a built-in palette."),
            ],
            required: ["type", "data"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        switch args.type {
        case .bar:
            return AnyView(BarChartView(args: args, isDarkMode: context.isDarkMode))
        case .line:
            return AnyView(LineChartView(args: args, isDarkMode: context.isDarkMode))
        case .pie:
            return AnyView(PieChartView(args: args, isDarkMode: context.isDarkMode))
        }
    }
}

private struct ChartEntry: Identifiable {
    let id: Int
    let label: String
    let value: Double
}

private func formatChartValue(_ value: Double) -> String {
    if value.truncatingRemainder(dividingBy: 1) == 0 {
        return String(Int(value))
    }
    return String(value)
}

private func chartAccessibilityLabel(kind: String, title: String?, entries: [ChartEntry]) -> String {
    var parts: [String] = []
    if let title, !title.isEmpty { parts.append(title) }
    parts.append(kind)
    let points = entries.map { "\($0.label) \(formatChartValue($0.value))" }
    if !points.isEmpty { parts.append(points.joined(separator: ", ")) }
    return parts.joined(separator: ". ")
}

/// Shared categorical X-axis modifier so bar and line charts use the
/// same downsampling and label formatting.
private struct CategoricalXAxisModifier: ViewModifier {
    let labels: [String]

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: visibleXAxisLabels(labels)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(compactXAxisLabel(label))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
            }
    }
}

private extension View {
    func categoricalXAxis(labels: [String]) -> some View {
        modifier(CategoricalXAxisModifier(labels: labels))
    }
}

private func resolvedChartEntries(_ args: ChartWidget.Args) -> (entries: [ChartEntry], keys: (x: String, y: String)) {
    let keys = inferChartKeys(args.data, preferredX: args.xKey, preferredY: args.yKey)
    let entries: [ChartEntry] = args.data
        .enumerated()
        .compactMap { index, row in
            guard let label = row.string(keys.x) ?? row.string(row.allKeys.first ?? "") else { return nil }
            guard let value = row.double(keys.y) else { return nil }
            return ChartEntry(id: index, label: label, value: value)
        }
    return (entries, keys)
}

private struct BarChartView: View {
    let args: ChartWidget.Args
    let isDarkMode: Bool

    var body: some View {
        let resolved = resolvedChartEntries(args)
        let color = parseHex(args.color) ?? GenUIStyle.accent

        VStack(alignment: .leading, spacing: 8) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            Chart(resolved.entries) { entry in
                BarMark(
                    x: .value(resolved.keys.x, entry.label),
                    y: .value(resolved.keys.y, entry.value)
                )
                .foregroundStyle(color)
                .cornerRadius(4)
            }
            .categoricalXAxis(labels: resolved.entries.map(\.label))
            .frame(height: GenUIStyle.chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chartAccessibilityLabel(kind: "Bar chart", title: args.title, entries: resolved.entries))
        }
        .genUICard(isDarkMode: isDarkMode)
    }
}

private struct LineChartView: View {
    let args: ChartWidget.Args
    let isDarkMode: Bool

    var body: some View {
        let resolved = resolvedChartEntries(args)
        let color = parseHex(args.color) ?? GenUIStyle.accent

        VStack(alignment: .leading, spacing: 8) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            Chart(resolved.entries) { entry in
                LineMark(
                    x: .value(resolved.keys.x, entry.label),
                    y: .value(resolved.keys.y, entry.value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value(resolved.keys.x, entry.label),
                    y: .value(resolved.keys.y, entry.value)
                )
                .foregroundStyle(color)
                .symbolSize(40)
            }
            .categoricalXAxis(labels: resolved.entries.map(\.label))
            .frame(height: GenUIStyle.chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chartAccessibilityLabel(kind: "Line chart", title: args.title, entries: resolved.entries))
        }
        .genUICard(isDarkMode: isDarkMode)
    }
}

private struct PieChartView: View {
    let args: ChartWidget.Args
    let isDarkMode: Bool

    private struct Slice: Identifiable {
        let id: Int
        let name: String
        let value: Double
    }

    var body: some View {
        let keys = inferChartKeys(args.data, preferredX: args.xKey, preferredY: args.yKey)
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
                .accessibilityHidden(true)

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
                        .accessibilityElement(children: .combine)
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
