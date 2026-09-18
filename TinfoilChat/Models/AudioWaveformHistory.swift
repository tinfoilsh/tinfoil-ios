import Foundation

struct AudioMeterSample {
    let decibels: Float
    let elapsedTime: TimeInterval
}

struct AudioWaveformHistory {
    private(set) var levels: [CGFloat] = []
    private(set) var elapsedTime: TimeInterval = .zero

    mutating func append(_ sample: AudioMeterSample) {
        guard sample.elapsedTime.isFinite, sample.elapsedTime >= .zero else { return }
        if sample.elapsedTime < elapsedTime {
            levels.removeAll(keepingCapacity: true)
        }
        elapsedTime = sample.elapsedTime
        levels.append(Self.normalizedLevel(decibels: sample.decibels))
        if levels.count > Constants.Audio.Waveform.maximumSamples {
            levels.removeFirst(levels.count - Constants.Audio.Waveform.maximumSamples)
        }
    }

    static func normalizedLevel(decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return .zero }
        let minimum = Constants.Audio.Waveform.minimumDecibels
        let maximum = Constants.Audio.Waveform.maximumDecibels
        let clamped = min(maximum, max(minimum, decibels))
        return CGFloat((clamped - minimum) / (maximum - minimum))
    }

    func barFrames(in size: CGSize, scrollFraction: CGFloat) -> [CGRect] {
        guard size.width.isFinite, size.height.isFinite,
              size.width > .zero, size.height > .zero else { return [] }
        let step = Constants.Audio.Waveform.barWidth + Constants.Audio.Waveform.barSpacing
        let count = Int(min(ceil(size.width / step) + 1, CGFloat(Constants.Audio.Waveform.maximumSamples)))
        let progress = scrollFraction.isFinite ? min(1, max(.zero, scrollFraction)) : .zero
        let minimumHeight = min(size.height, Constants.Audio.Waveform.minimumBarHeight)
        let maximumHeight = min(size.height, Constants.Audio.Waveform.height)

        return (0..<count).map { distanceFromNewest in
            let level = distanceFromNewest < levels.count ? levels[levels.count - 1 - distanceFromNewest] : .zero
            let height = minimumHeight + level * (maximumHeight - minimumHeight)
            return CGRect(
                x: size.width - Constants.Audio.Waveform.barWidth - CGFloat(distanceFromNewest) * step - progress * step,
                y: (size.height - height) / 2,
                width: Constants.Audio.Waveform.barWidth,
                height: height
            )
        }
    }
}
