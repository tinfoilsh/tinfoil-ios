//
//  BarChartWidget.swift
//  TinfoilChat
//

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
            if n.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(n)) }
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
    let order = firstKeys.isEmpty ? allKeys : firstKeys

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

struct BarChartWidget: GenUIWidget {
    struct Args: Decodable {
        let data: [ChartRow]
        let xKey: String?
        let yKey: String?
        let title: String?
        let color: String?
    }

    let name = "render_bar_chart"
    let description = "Render a bar chart for categorical comparisons. Use when comparing values across categories."
    let promptHint = "categorical comparisons as bars"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "data": GenUISchema.array(
                    items: GenUISchema.openObjectOfStringOrNumber(),
                    description: "Data points sharing the same keys, e.g. [{\"label\":\"A\",\"value\":10}, ...]",
                    minItems: 1
                ),
                "xKey": GenUISchema.string(description: "Key for category axis"),
                "yKey": GenUISchema.string(description: "Key for numeric axis"),
                "title": GenUISchema.string(),
                "color": GenUISchema.string(description: "Bar color hex string"),
            ],
            required: ["data"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(BarChartView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct BarChartView: View {
    let args: BarChartWidget.Args
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
                BarMark(
                    x: .value(keys.x, entry.label),
                    y: .value(keys.y, entry.value)
                )
                .foregroundStyle(color)
                .cornerRadius(4)
            }
            .frame(height: GenUIStyle.chartHeight)
        }
        .genUICard(isDarkMode: isDarkMode)
    }
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
