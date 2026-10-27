import Testing
@testable import TinfoilChat

struct SpeechBufferTests {
    private let samples = [Float](repeating: 0.5, count: Constants.Speech.blockSamples)
    private let startupBlocks = Constants.Speech.startBufferSeconds * Constants.Speech.sampleRate / Constants.Speech.blockSamples

    @Test
    func playbackStartsOnceEnoughAudioArrived() throws {
        var buffer = SpeechBuffer()
        for _ in 0..<(startupBlocks - 1) { try buffer.append(samples) }
        #expect(buffer.takePlayableBlocks().isEmpty)
        #expect(!buffer.isPlaying)
        try buffer.append(samples)
        #expect(buffer.takePlayableBlocks().count == startupBlocks)
        #expect(buffer.isPlaying)
    }

    @Test
    func completeShortResponseStartsAndWaitsForActualPlayback() throws {
        var buffer = SpeechBuffer()
        try buffer.append([0.25, -0.25])
        #expect(buffer.takePlayableBlocks().isEmpty)
        try buffer.finish()
        #expect(buffer.takePlayableBlocks() == [[0.25, -0.25]])
        #expect(!buffer.isFinished)
        buffer.didPlay(sampleCount: 2)
        #expect(buffer.isFinished)
        #expect(buffer.bufferedSamples == 0)
    }

    @Test
    func schedulingDoesNotFreeTheBufferedBudget() throws {
        var buffer = SpeechBuffer()
        let blocksAtHighWater = Constants.Speech.maxBufferedSamples / samples.count
        for _ in 0..<blocksAtHighWater { try buffer.append(samples) }
        #expect(buffer.isFull)
        #expect(buffer.takePlayableBlocks().count == blocksAtHighWater)
        #expect(buffer.isFull)
        buffer.didPlay(sampleCount: samples.count)
        #expect(!buffer.isFull)
    }

    @Test
    func underrunRebuffersInsteadOfPlayingEveryTinyArrival() throws {
        var buffer = SpeechBuffer()
        for _ in 0..<startupBlocks { try buffer.append(samples) }
        for block in buffer.takePlayableBlocks() { buffer.didPlay(sampleCount: block.count) }
        #expect(buffer.takePlayableBlocks().isEmpty)
        #expect(!buffer.isPlaying)
        try buffer.append(samples)
        #expect(buffer.takePlayableBlocks().isEmpty)
        try buffer.finish()
        #expect(buffer.takePlayableBlocks().count == 1)
        #expect(buffer.isPlaying)
    }

    @Test
    func completionAfterLastPlaybackStillFinishesTheSession() throws {
        var buffer = SpeechBuffer()
        for _ in 0..<startupBlocks { try buffer.append(samples) }
        for block in buffer.takePlayableBlocks() { buffer.didPlay(sampleCount: block.count) }
        #expect(!buffer.isFinished)
        try buffer.finish()
        #expect(buffer.takePlayableBlocks().isEmpty)
        #expect(buffer.isFinished)
    }

    @Test
    func enforcesBlockSizeAndRefusesAnEmptyOrEndedStream() throws {
        var buffer = SpeechBuffer()
        #expect(throws: SpeechError.invalidAudio) { try buffer.append(samples + [0]) }
        #expect(throws: SpeechError.invalidAudio) { try buffer.finish() }
        try buffer.append(samples)
        try buffer.finish()
        #expect(throws: SpeechError.invalidAudio) { try buffer.append([0]) }
        #expect(throws: SpeechError.invalidAudio) { try buffer.finish() }
    }
}
