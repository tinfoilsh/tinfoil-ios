//
//  CountdownWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct CountdownWidget: GenUIWidget {
    struct Args: Decodable {
        let durationSeconds: Double?
        let target: String?
        let label: String?
        let title: String?
        let description: String?
        let completedMessage: String?
        let alarmMode: String?
    }

    let name = "render_countdown"
    let description = "Display an engaging timer that ticks down from a duration, then beeps or silently flashes when done. Use for timers, breaks, reminders, workouts, cooking, and other timed activities."
    let promptHint = "interactive timer with a circular countdown and restart"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "durationSeconds": GenUISchema.number(description: "Timer duration in seconds. Prefer for requests like \"set a 5 minute timer\"."),
                "target": GenUISchema.string(description: "ISO date-time when the timer should end."),
                "label": GenUISchema.string(),
                "title": GenUISchema.string(),
                "description": GenUISchema.string(),
                "completedMessage": GenUISchema.string(),
                "alarmMode": GenUISchema.string(enumValues: ["sound", "flash"]),
            ]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(CountdownView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct CountdownView: View {
    let args: CountdownWidget.Args
    let isDarkMode: Bool

    @State private var endDate: Date = Date()
    @State private var totalDuration: TimeInterval = 0
    @State private var isPaused: Bool = true
    @State private var pausedRemaining: TimeInterval = 0
    @State private var hasStarted: Bool = false
    @State private var dismissed: Bool = false

    private static let accent: Color = Color(red: 0.96, green: 0.70, blue: 0.29)

    var body: some View {
        VStack(spacing: 16) {
            if let title = args.title ?? args.label, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
            } else {
                Text("Timer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
            }
            if let description = args.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    .multilineTextAlignment(.center)
            }

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = currentRemaining(at: context.date)
                let progress = max(0, min(1, remaining / max(totalDuration, 1)))

                ZStack {
                    Circle()
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(Self.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: progress)
                    Text(formatRemaining(remaining))
                        .font(.system(size: 36, weight: .light, design: .monospaced))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
                .frame(width: 200, height: 200)
                .opacity((remaining <= 0 && !dismissed) ? 0.7 : 1.0)
            }

            HStack(spacing: 12) {
                Button(action: handleSecondary) {
                    Text(secondaryLabel())
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 80, height: 80)
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .background(
                            Circle().fill(GenUIStyle.subtleBackground(isDarkMode))
                        )
                }
                .buttonStyle(.plain)

                Button(action: handlePrimary) {
                    Text(primaryLabel())
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 80, height: 80)
                        .foregroundColor(.black)
                        .background(Circle().fill(Self.accent))
                }
                .buttonStyle(.plain)
                .disabled(isFinished())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .genUICard(isDarkMode: isDarkMode, padding: 0)
        .onAppear(perform: configure)
    }

    private func configure() {
        if let duration = args.durationSeconds, duration > 0 {
            totalDuration = duration
            pausedRemaining = duration
            endDate = Date().addingTimeInterval(duration)
            isPaused = true
            hasStarted = false
        } else if let targetString = args.target,
                  let target = ISO8601DateFormatter().date(from: targetString) {
            let interval = target.timeIntervalSinceNow
            totalDuration = max(1, interval)
            pausedRemaining = max(0, interval)
            endDate = target
            isPaused = false
            hasStarted = true
        }
    }

    private func currentRemaining(at date: Date) -> TimeInterval {
        if isPaused { return pausedRemaining }
        return max(0, endDate.timeIntervalSince(date))
    }

    private func isFinished() -> Bool {
        currentRemaining(at: Date()) <= 0
    }

    private func formatRemaining(_ value: TimeInterval) -> String {
        let total = Int(ceil(value))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func handlePrimary() {
        if isFinished() { return }
        if isPaused {
            // resume
            endDate = Date().addingTimeInterval(pausedRemaining)
            isPaused = false
            hasStarted = true
        } else {
            // pause
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            isPaused = true
        }
    }

    private func handleSecondary() {
        if isFinished() {
            dismissed = true
            return
        }
        // restart
        if let duration = args.durationSeconds, duration > 0 {
            totalDuration = duration
            pausedRemaining = duration
            endDate = Date().addingTimeInterval(duration)
            isPaused = true
            hasStarted = false
        }
    }

    private func primaryLabel() -> String {
        if isPaused { return hasStarted ? "Resume" : "Start" }
        return "Pause"
    }

    private func secondaryLabel() -> String {
        if isFinished() { return "Done" }
        return hasStarted ? "Restart" : "Reset"
    }
}
