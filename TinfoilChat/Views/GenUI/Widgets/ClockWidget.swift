//
//  ClockWidget.swift
//  TinfoilChat
//
//  Unified clock widget. Displays either a live analog clock or a
//  countdown timer driven by `mode`. Mirrors the webapp's `render_clock`
//  widget.

import AVFoundation
import OpenAI
import SwiftUI
import UIKit

private let maxTimerSeconds: Double = 604_800

struct ClockWidget: GenUIWidget {
    enum ClockMode: String, Decodable {
        case clock
        case timer
    }

    struct Args: Decodable {
        let mode: ClockMode?
        let label: String?
        let title: String?
        let description: String?
        let timeZone: String?
        let showSeconds: Bool?
        let showDate: Bool?
        let durationSeconds: Double?
        let target: String?
        let completedMessage: String?
        let alarmMode: String?
    }

    let name = "render_clock"
    let description = """
        Display either a live analog clock (mode "clock") or an interactive \
        countdown timer (mode "timer"). Use "clock" for the current time in a \
        time zone. Use "timer" for "set a 5 minute timer", reminders, breaks, \
        workouts, cooking, etc.
        """
    let promptHint = "a live analog clock OR a countdown timer — pass mode \"clock\" with optional timeZone for time display, or mode \"timer\" with durationSeconds (or target ISO date) for countdowns"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "mode": GenUISchema.string(
                    description: "What to display. \"clock\" shows the current time as an analog face. \"timer\" counts down from a duration or to a target time. Defaults to \"clock\".",
                    enumValues: ["clock", "timer"]
                ),
                "label": GenUISchema.string(description: "Short label, e.g. \"New York\" for a clock or \"Tea\" for a timer."),
                "title": GenUISchema.string(description: "Main title (timer mode)"),
                "description": GenUISchema.string(description: "Optional description"),
                "timeZone": GenUISchema.string(description: "Clock mode only. IANA time zone, e.g. \"America/New_York\". Defaults to local."),
                "showSeconds": GenUISchema.boolean(description: "Clock mode: include the second hand (default true)."),
                "showDate": GenUISchema.boolean(description: "Clock mode: include date line (default true)."),
                "durationSeconds": GenUISchema.number(
                    description: "Timer mode. Duration in seconds. Prefer this for requests like \"set a 5 minute timer\".",
                    maximum: maxTimerSeconds,
                    exclusiveMinimum: 0
                ),
                "target": GenUISchema.string(description: "Timer mode. ISO date-time when the timer should end, e.g. \"2026-12-31T23:59:59Z\". Use when an exact end time is known."),
                "completedMessage": GenUISchema.string(description: "Timer mode. Message shown when the timer finishes."),
                "alarmMode": GenUISchema.string(
                    description: "Timer mode. Alarm behavior when done. \"sound\" beeps; \"flash\" stays silent and flashes visually. Defaults to sound.",
                    enumValues: ["sound", "flash"]
                ),
            ]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        let resolved = resolveMode(args)
        switch resolved {
        case .timer:
            return AnyView(CountdownView(args: args, isDarkMode: context.isDarkMode))
        case .clock:
            return AnyView(ClockFaceView(args: args, isDarkMode: context.isDarkMode))
        }
    }

    private func resolveMode(_ args: Args) -> ClockMode {
        if let mode = args.mode { return mode }
        if let duration = args.durationSeconds, duration > 0 { return .timer }
        if let target = args.target, !target.isEmpty { return .timer }
        return .clock
    }
}

// MARK: - Clock face

private struct ClockFaceView: View {
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

// MARK: - Countdown timer

/// Repeats a synthesized sine-tone beep + haptic at a fixed cadence until
/// stopped. The webapp uses WebAudio to synthesize a short tone every
/// ~850ms; on iOS we synthesize the same tone in-process and play it via
/// `AVAudioPlayer` over a `.playback` audio session so the alarm remains
/// audible even when the silent switch is on. Haptic feedback fires in
/// lockstep so the alarm is felt and heard.
@MainActor
private final class TimerAlarmController: ObservableObject {
    private static let beepIntervalSeconds: TimeInterval = 0.85
    private static let beepFrequencyHz: Double = 880
    private static let beepDurationSeconds: Double = 0.18
    private static let beepSampleRate: Double = 44_100

    private var timer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)

    func start(mode: TimerAlarmMode) {
        stop()
        notificationGenerator.prepare()
        impactGenerator.prepare()
        // `.playback` category lets the alarm play even when the silent
        // switch is on. Mix politely with any audio the user has playing.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers, .duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true, options: [])

        if mode == .sound {
            audioPlayer = Self.makeBeepPlayer()
            audioPlayer?.prepareToPlay()
        }

        // Fire one immediately so the user gets feedback right when the
        // timer hits zero, then continue at a steady cadence.
        fire(mode: mode)
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.beepIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fire(mode: mode)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func fire(mode: TimerAlarmMode) {
        // Strong haptic feedback for both modes; only the beep is muted
        // when the model asks for a silent flash alarm.
        notificationGenerator.notificationOccurred(.warning)
        impactGenerator.impactOccurred()
        if mode == .sound, let player = audioPlayer {
            player.currentTime = 0
            player.play()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private static func makeBeepPlayer() -> AVAudioPlayer? {
        let sampleCount = Int(beepDurationSeconds * beepSampleRate)
        let fadeSamples = max(1, Int(0.01 * beepSampleRate))
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let envelope: Double
            if i < fadeSamples {
                envelope = Double(i) / Double(fadeSamples)
            } else if i > sampleCount - fadeSamples {
                envelope = Double(sampleCount - i) / Double(fadeSamples)
            } else {
                envelope = 1
            }
            let phase = 2.0 * .pi * beepFrequencyHz * Double(i) / beepSampleRate
            let value = sin(phase) * envelope * 0.6
            samples[i] = Int16(max(-1.0, min(1.0, value)) * Double(Int16.max))
        }
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        let dataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        data.append(contentsOf: uint32LE(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: uint32LE(16))
        data.append(contentsOf: uint16LE(1))
        data.append(contentsOf: uint16LE(1))
        data.append(contentsOf: uint32LE(UInt32(beepSampleRate)))
        data.append(contentsOf: uint32LE(UInt32(beepSampleRate) * 2))
        data.append(contentsOf: uint16LE(2))
        data.append(contentsOf: uint16LE(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: uint32LE(dataByteCount))
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                data.append(
                    Data(
                        bytes: base,
                        count: buffer.count * MemoryLayout<Int16>.size
                    )
                )
            }
        }
        return try? AVAudioPlayer(data: data)
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}

private enum TimerAlarmMode: String {
    case sound
    case flash

    init(rawArg: String?) {
        switch rawArg?.lowercased() {
        case "flash": self = .flash
        default: self = .sound
        }
    }
}

private struct CountdownView: View {
    let args: ClockWidget.Args
    let isDarkMode: Bool

    @State private var endDate: Date = Date()
    @State private var totalDuration: TimeInterval = 0
    @State private var isPaused: Bool = true
    @State private var pausedRemaining: TimeInterval = 0
    @State private var hasStarted: Bool = false
    @State private var dismissed: Bool = false
    @State private var alarmActive: Bool = false
    @State private var flashOn: Bool = false
    @State private var hasConfigured: Bool = false
    @StateObject private var alarm = TimerAlarmController()

    private static let accent: Color = Color(red: 0.96, green: 0.70, blue: 0.29)

    private var alarmMode: TimerAlarmMode {
        TimerAlarmMode(rawArg: args.alarmMode)
    }

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
                let finishedNow = remaining <= 0 && hasStarted && !dismissed
                let triggerAlarm = finishedNow && !alarmActive

                ZStack {
                    Circle()
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(Self.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: progress)
                    Text(formatRemaining(max(0, remaining)))
                        .font(.system(size: 36, weight: .light, design: .monospaced))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
                .frame(width: 200, height: 200)
                .opacity(finishedNow && alarmMode == .flash && !flashOn ? 0.4 : 1.0)
                .onChange(of: triggerAlarm) { _, shouldStart in
                    if shouldStart { startAlarm() }
                }
            }

            if isFinished() && hasStarted {
                Text(finishedLabel())
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Self.accent)
                    .multilineTextAlignment(.center)
            }

            if isFinished() && hasStarted {
                Button(action: handlePrimary) {
                    Text(primaryLabel())
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundColor(.black)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Self.accent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            } else {
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
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .genUICard(isDarkMode: isDarkMode, padding: 0)
        .onAppear(perform: configure)
        .onDisappear { alarm.stop() }
    }

    private func configure() {
        // `onAppear` fires every time the cell scrolls back into view in
        // a lazy container; preserve any running countdown state by only
        // initializing once per view lifetime.
        guard !hasConfigured else { return }
        hasConfigured = true
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

    private func finishedLabel() -> String {
        args.completedMessage ?? "Time's up"
    }

    private func handlePrimary() {
        // While the alarm is sounding the primary button silences it and
        // marks the run as dismissed, so the user has a single obvious tap
        // target to make the noise stop without losing the timer.
        if alarmActive {
            stopAlarm()
            dismissed = true
            return
        }
        if isFinished() {
            // Past the deadline with no alarm running (e.g. tabbed away);
            // tapping primary just resets the timer so it can run again.
            resetTimer()
            return
        }
        if isPaused {
            endDate = Date().addingTimeInterval(pausedRemaining)
            isPaused = false
            hasStarted = true
        } else {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            isPaused = true
        }
    }

    private func handleSecondary() {
        // The secondary button is always a "back to the start" action so a
        // finished timer can be restarted instead of getting stuck on a
        // dead "Done" button.
        if alarmActive { stopAlarm() }
        resetTimer()
    }

    private func resetTimer() {
        if let duration = args.durationSeconds, duration > 0 {
            totalDuration = duration
            pausedRemaining = duration
            endDate = Date().addingTimeInterval(duration)
            isPaused = true
            hasStarted = false
            dismissed = false
        } else if let targetString = args.target,
                  let target = ISO8601DateFormatter().date(from: targetString) {
            let interval = target.timeIntervalSinceNow
            totalDuration = max(1, interval)
            pausedRemaining = max(0, interval)
            endDate = target
            isPaused = false
            hasStarted = true
            dismissed = false
        }
    }

    private func startAlarm() {
        alarmActive = true
        alarm.start(mode: alarmMode)
        if alarmMode == .flash {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                flashOn.toggle()
            }
        }
    }

    private func stopAlarm() {
        alarm.stop()
        alarmActive = false
        flashOn = false
    }

    private func primaryLabel() -> String {
        if alarmActive { return "Stop" }
        if isFinished() && hasStarted { return "Restart" }
        if isPaused { return hasStarted ? "Resume" : "Start" }
        return "Pause"
    }

    private func secondaryLabel() -> String {
        if isFinished() && hasStarted { return "Restart" }
        return hasStarted ? "Restart" : "Reset"
    }
}
