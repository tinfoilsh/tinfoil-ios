//
//  ClockWidget.swift
//  TinfoilChat
//
//  Live analog clock face with optional time zone, mirroring the webapp's
//  `render_clock` widget.

import OpenAI
import SwiftUI

struct ClockWidget: GenUIWidget {
    struct Args: Decodable {
        let label: String?
        let timeZone: String?
        let showSeconds: Bool?
        let showDate: Bool?
    }

    let name = "render_clock"
    let description = "Display a live analog clock face with hour/minute/second hands, optionally for a specific time zone."
    let promptHint = "a live analog clock face with hands and hour numerals, optionally for a time zone"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "label": GenUISchema.string(description: "Short label, e.g. \"New York\""),
                "timeZone": GenUISchema.string(description: "IANA time zone, e.g. \"America/New_York\". Defaults to local."),
                "showSeconds": GenUISchema.boolean(description: "Include the second hand (default true)"),
                "showDate": GenUISchema.boolean(description: "Include date line (default true)"),
            ]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(ClockView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct ClockView: View {
    let args: ClockWidget.Args
    let isDarkMode: Bool

    private var timeZone: TimeZone {
        if let id = args.timeZone, let zone = TimeZone(identifier: id) { return zone }
        return TimeZone.current
    }

    private var showSeconds: Bool { args.showSeconds ?? true }
    private var showDate: Bool { args.showDate ?? true }

    var body: some View {
        VStack(spacing: 8) {
            if let label = args.label, !label.isEmpty {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.0)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }

            TimelineView(.animation(minimumInterval: showSeconds ? 0.05 : 1.0, paused: false)) { context in
                let date = context.date
                ClockDial(date: date, timeZone: timeZone, showSeconds: showSeconds, isDarkMode: isDarkMode)
                    .frame(width: 160, height: 160)
            }

            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                VStack(spacing: 2) {
                    Text(timeString(for: context.date))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    if showDate {
                        Text(dateString(for: context.date))
                            .font(.caption)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .genUICard(isDarkMode: isDarkMode, padding: 16)
    }

    private func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = showSeconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy"
        let zoneSuffix = args.timeZone.map { " \u{00B7} \($0)" } ?? ""
        return formatter.string(from: date) + zoneSuffix
    }
}

private struct ClockDial: View {
    let date: Date
    let timeZone: TimeZone
    let showSeconds: Bool
    let isDarkMode: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = size / 2 - 4

            ZStack {
                Circle()
                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                ForEach(0..<60, id: \.self) { tick in
                    tickMark(tick: tick, center: center, radius: radius)
                }

                ForEach(1...12, id: \.self) { hour in
                    let angle = Angle.degrees(Double(hour) * 30 - 90)
                    let pos = polar(center: center, radius: radius - 16, angle: angle)
                    Text("\(hour)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .position(pos)
                }

                let parts = timeParts(for: date)
                let hourAngle = ((Double(parts.hour % 12) + parts.minute / 60.0 + parts.second / 3600.0) * 30) - 90
                let minuteAngle = ((parts.minute + parts.second / 60.0) * 6) - 90
                let secondAngle = (parts.second * 6) - 90

                hand(center: center, length: radius - 55, angle: .degrees(hourAngle), width: 4,
                     color: GenUIStyle.primaryText(isDarkMode))
                hand(center: center, length: radius - 25, angle: .degrees(minuteAngle), width: 2.5,
                     color: GenUIStyle.primaryText(isDarkMode))
                if showSeconds {
                    hand(center: center, length: radius - 18, angle: .degrees(secondAngle), width: 1.5,
                         color: .red)
                }

                Circle()
                    .fill(GenUIStyle.primaryText(isDarkMode))
                    .frame(width: 7, height: 7)
                    .position(center)
                if showSeconds {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 3, height: 3)
                        .position(center)
                }
            }
        }
    }

    private func tickMark(tick: Int, center: CGPoint, radius: CGFloat) -> some View {
        let isMajor = tick % 5 == 0
        let inner = isMajor ? radius - 10 : radius - 5
        let outer = radius - 2
        let angle = Angle.degrees(Double(tick) * 6 - 90)
        let p1 = polar(center: center, radius: inner, angle: angle)
        let p2 = polar(center: center, radius: outer, angle: angle)

        return Path { path in
            path.move(to: p1)
            path.addLine(to: p2)
        }
        .stroke(
            GenUIStyle.primaryText(isDarkMode).opacity(isMajor ? 0.7 : 0.25),
            style: StrokeStyle(lineWidth: isMajor ? 2 : 1, lineCap: .round)
        )
    }

    private func hand(center: CGPoint, length: CGFloat, angle: Angle, width: CGFloat, color: Color) -> some View {
        let end = polar(center: center, radius: length, angle: angle)
        return Path { path in
            path.move(to: center)
            path.addLine(to: end)
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func polar(center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(
            x: center.x + radius * CGFloat(cos(angle.radians)),
            y: center.y + radius * CGFloat(sin(angle.radians))
        )
    }

    private func timeParts(for date: Date) -> (hour: Int, minute: Double, second: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = components.hour ?? 0
        let minute = Double(components.minute ?? 0)
        let nano = Double(components.nanosecond ?? 0) / 1_000_000_000
        let second = Double(components.second ?? 0) + nano
        return (hour, minute, second)
    }
}
