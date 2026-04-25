//
//  TimelineWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct TimelineWidget: GenUIWidget {
    struct Event: Decodable {
        let date: String
        let title: String
        let description: String?
    }

    struct Args: Decodable {
        let events: [Event]
        let title: String?
    }

    let name = "render_timeline"
    let description = "Display a chronological timeline of events. Use for history, news recaps, or project milestones."
    let promptHint = "chronological events, history, news recaps, or milestones"

    var schema: JSONSchema {
        let eventSchema = GenUISchema.object(
            properties: [
                "date": GenUISchema.string(),
                "title": GenUISchema.string(),
                "description": GenUISchema.string(),
            ],
            required: ["date", "title"]
        )
        return GenUISchema.object(
            properties: [
                "events": GenUISchema.array(
                    items: eventSchema,
                    description: "Chronological events",
                    minItems: 1
                ),
                "title": GenUISchema.string(),
            ],
            required: ["events"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(TimelineEventsView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct TimelineEventsView: View {
    let args: TimelineWidget.Args
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(args.events.enumerated()), id: \.offset) { index, event in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack(alignment: .top) {
                            // Connector line
                            Rectangle()
                                .fill(GenUIStyle.borderColor(isDarkMode))
                                .frame(width: 1)
                                .padding(.top, 18)
                                .opacity(index == args.events.count - 1 ? 0 : 1)

                            Circle()
                                .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 2)
                                .background(Circle().fill(GenUIStyle.cardBackground(isDarkMode)))
                                .frame(width: 12, height: 12)
                                .padding(.top, 4)
                        }
                        .frame(width: 14)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.date.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.5)
                                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            Text(event.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                            if let description = event.description, !description.isEmpty {
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
    }
}
