import Foundation
import Testing
@testable import TinfoilChat

struct AudioWaveformHistoryTests {
    @Test(arguments: [
        (Float(-160), CGFloat.zero),
        (Float(-60), CGFloat.zero),
        (Float(-30), CGFloat(0.5)),
        (Float.zero, CGFloat(1)),
        (Float(10), CGFloat(1)),
        (Float.nan, CGFloat.zero),
        (Float.infinity, CGFloat.zero),
        (-Float.infinity, CGFloat.zero),
    ])
    func scalesActualMicrophonePower(decibels: Float, expected: CGFloat) {
        #expect(AudioWaveformHistory.normalizedLevel(decibels: decibels) == expected)
    }

    @Test
    func retainsOnlyTheNewestLevelsInOrder() {
        var history = AudioWaveformHistory()
        let sampleCount = Constants.Audio.Waveform.maximumSamples + 3
        let powers: [Float] = [-60, -40, -20, 0]
        var expected: [CGFloat] = []
        for index in 0..<sampleCount {
            let power = powers[index % powers.count]
            history.append(AudioMeterSample(decibels: power, elapsedTime: TimeInterval(index)))
            expected.append(AudioWaveformHistory.normalizedLevel(decibels: power))
        }

        #expect(history.levels == Array(expected.suffix(Constants.Audio.Waveform.maximumSamples)))
        #expect(history.elapsedTime == TimeInterval(sampleCount - 1))
    }

    @Test
    func resetsHistoryWhenARecordingStartsOver() {
        var history = AudioWaveformHistory()
        history.append(AudioMeterSample(decibels: -30, elapsedTime: 12))
        history.append(AudioMeterSample(decibels: 0, elapsedTime: 0))

        #expect(history.levels == [1])
        #expect(history.elapsedTime == .zero)
    }

    @Test(arguments: [-TimeInterval(1), TimeInterval.nan, TimeInterval.infinity])
    func ignoresInvalidRecorderTimes(time: TimeInterval) {
        var history = AudioWaveformHistory()
        history.append(AudioMeterSample(decibels: -30, elapsedTime: 1))
        history.append(AudioMeterSample(decibels: 0, elapsedTime: time))

        #expect(history.levels == [0.5])
        #expect(history.elapsedTime == 1)
    }

    @Test
    func addsNewBarsOnTheRightAndMovesOlderBarsLeft() throws {
        var history = AudioWaveformHistory()
        let size = CGSize(width: 200, height: Constants.Audio.Waveform.height)
        let step = Constants.Audio.Waveform.barWidth + Constants.Audio.Waveform.barSpacing
        history.append(AudioMeterSample(decibels: -30, elapsedTime: 1))
        let original = try #require(history.barFrames(in: size, scrollFraction: 0).first)
        let halfway = try #require(history.barFrames(in: size, scrollFraction: 0.5).first)
        #expect(halfway.minX == original.minX - step / 2)
        #expect(halfway.height == original.height)

        history.append(AudioMeterSample(decibels: 0, elapsedTime: 1 + Constants.Audio.Waveform.sampleInterval))
        let frames = history.barFrames(in: size, scrollFraction: 0)
        try #require(frames.count >= 2)
        #expect(frames[0].maxX == size.width)
        #expect(frames[0].height == Constants.Audio.Waveform.height)
        #expect(frames[1].minX == original.minX - step)
        #expect(frames[1].height == original.height)
    }

    @Test
    func silenceUsesSmallBarsAndStaysWithinTheAvailableHeight() {
        let history = AudioWaveformHistory()
        let size = CGSize(width: 200, height: Constants.Audio.Waveform.height)
        let frames = history.barFrames(in: size, scrollFraction: 0)
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.height == Constants.Audio.Waveform.minimumBarHeight })

        let shortSize = CGSize(width: size.width, height: 1)
        let shortFrames = history.barFrames(in: shortSize, scrollFraction: 0)
        #expect(shortFrames.allSatisfy { $0.minY >= .zero && $0.maxY <= shortSize.height })
        #expect(history.barFrames(in: .zero, scrollFraction: 0).isEmpty)
    }
}
