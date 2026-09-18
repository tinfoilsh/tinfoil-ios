import Combine
import SwiftUI

struct AudioRecordingWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history = AudioWaveformHistory()
    @State private var lastSampleAt = Date.now
    @ObservedObject var recordingService: AudioRecordingService

    @State private var meterTimer = Timer.publish(
        every: Constants.Audio.Waveform.sampleInterval,
        on: .main,
        in: .common
    ).autoconnect()

    private var elapsedText: String {
        Duration.seconds(history.elapsedTime.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }

    var body: some View {
        HStack(spacing: Constants.Audio.Waveform.contentSpacing) {
            Text(Duration.seconds(Constants.Audio.recordingTimeoutSeconds).formatted(.time(pattern: .minuteSecond)))
                .hidden()
                .overlay(alignment: .leading) {
                    Text(elapsedText)
                }
                .font(.body.monospacedDigit())
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording time")
                .accessibilityValue(elapsedText)

            TimelineView(.animation(
                minimumInterval: Constants.Audio.Waveform.frameInterval,
                paused: reduceMotion || !recordingService.isRecording
            )) { timeline in
                Canvas { context, size in
                    let progress = reduceMotion ? .zero : CGFloat(
                        timeline.date.timeIntervalSince(lastSampleAt) / Constants.Audio.Waveform.sampleInterval
                    )
                    let radius = Constants.Audio.Waveform.barWidth / 2
                    var path = Path()
                    for frame in history.barFrames(in: size, scrollFraction: progress) {
                        path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius, height: radius))
                    }
                    context.fill(path, with: .color(.secondary))
                }
            }
            .frame(height: Constants.Audio.Waveform.height)
            .clipped()
            .accessibilityHidden(true)
        }
        .onAppear { sampleMeter(at: .now) }
        .onReceive(meterTimer) { sampleMeter(at: $0) }
    }

    private func sampleMeter(at date: Date) {
        guard let sample = recordingService.meteringSample() else { return }
        history.append(sample)
        lastSampleAt = date
    }
}
