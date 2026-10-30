//
//  StatCardsWidget.swift
//  TinfoilChat
//

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

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(StatCardsView(stats: args.stats, isDarkMode: context.isDarkMode))
    }
}

private struct StatCardsView: View {
    let stats: [StatCardsWidget.Stat]
    let isDarkMode: Bool

    private enum Layout {
        static let gridSpacing: CGFloat = 8
        static let contentSpacing: CGFloat = 6
        static let cardPadding: CGFloat = 12
    }

    @State private var maximumCardContentHeight: CGFloat = 0

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: Layout.gridSpacing),
            GridItem(.flexible(), spacing: Layout.gridSpacing),
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Layout.gridSpacing) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                VStack(alignment: .leading, spacing: Layout.contentSpacing) {
                    Text(stat.label)
                        .font(.caption.weight(.medium))
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        .fixedSize(horizontal: false, vertical: true)

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
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: StatCardHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: maximumCardContentHeight,
                    alignment: .topLeading
                )
                .genUICard(isDarkMode: isDarkMode, padding: Layout.cardPadding)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(statAccessibilityLabel(stat))
            }
        }
        .onPreferenceChange(StatCardHeightPreferenceKey.self) { height in
            maximumCardContentHeight = height
        }
    }

    private func statAccessibilityLabel(_ stat: StatCardsWidget.Stat) -> String {
        var label = "\(stat.label), \(stat.value.stringValue)"
        if stat.trend == "up" {
            label += ", trending up"
        } else if stat.trend == "down" {
            label += ", trending down"
        }
        return label
    }
}

struct StatCardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
