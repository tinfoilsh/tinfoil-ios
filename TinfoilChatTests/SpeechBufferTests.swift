import Testing
@testable import TinfoilChat

struct SpeechBufferTests {
    private let samples = [Float](repeating: 0.5, count: Constants.Speech.blockSamples)

    @Test
    func reservesAtMostTwoConcurrentRequests() {
        var buffer = SpeechBuffer(chunkCount: 10)
        #expect(buffer.reserveRequests() == [0, 1])
        #expect(buffer.reserveRequests().isEmpty)
        #expect(buffer.inFlight == Constants.Speech.concurrentRequests)
    }

    @Test
    func outOfOrderAudioDoesNotCountTowardContiguousStartup() throws {
        var buffer = SpeechBuffer(chunkCount: 2)
        _ = buffer.reserveRequests()
        try buffer.append(samples, to: 1)
        try buffer.finishRequest(1)
        let startupBlocks = Constants.Speech.startBufferSeconds * Constants.Speech.sampleRate / samples.count
        for _ in 0..<(startupBlocks - 1) { try buffer.append(samples, to: 0) }
        #expect(buffer.takePlayableBlocks().isEmpty)
        try buffer.append(samples, to: 0)
        let first = buffer.takePlayableBlocks()
        #expect(first.count == startupBlocks)
        #expect(first.allSatisfy { $0.chunkIndex == 0 })
        #expect(buffer.isPlaying)
        try buffer.finishRequest(0)
        let second = buffer.takePlayableBlocks()
        #expect(second.count == 1)
        #expect(second.first?.chunkIndex == 1)
    }

    @Test
    func completeShortResponseStartsAndWaitsForActualPlayback() throws {
        var buffer = SpeechBuffer(chunkCount: 1)
        _ = buffer.reserveRequests()
        try buffer.append([0.25, -0.25], to: 0)
        #expect(buffer.takePlayableBlocks().isEmpty)
        try buffer.finishRequest(0)
        let blocks = buffer.takePlayableBlocks()
        #expect(blocks.map(\.samples) == [[0.25, -0.25]])
        #expect(!buffer.isFinished)
        buffer.didPlay(chunkIndex: 0, sampleCount: 2)
        #expect(buffer.isFinished)
        #expect(buffer.bufferedSamples == 0)
    }

    @Test
    func fullShortLookaheadWindowDoesNotDeadlockStartup() throws {
        var buffer = SpeechBuffer(chunkCount: Constants.Speech.lookaheadChunks + 2)
        for index in 0..<Constants.Speech.lookaheadChunks {
            _ = buffer.reserveRequests()
            try buffer.append([Float(index)], to: index)
            try buffer.finishRequest(index)
            if index < Constants.Speech.lookaheadChunks - 1 { #expect(buffer.takePlayableBlocks().isEmpty) }
        }
        let blocks = buffer.takePlayableBlocks()
        #expect(blocks.map(\.chunkIndex) == Array(0..<Constants.Speech.lookaheadChunks))
        #expect(buffer.reserveRequests().isEmpty)
        buffer.didPlay(chunkIndex: 0, sampleCount: 1)
        #expect(buffer.reserveRequests() == [Constants.Speech.lookaheadChunks])
    }

    @Test
    func schedulingDoesNotFreeTheGenerationHighWaterBudget() throws {
        var buffer = SpeechBuffer(chunkCount: 8)
        _ = buffer.reserveRequests()
        let blocksAtHighWater = Constants.Speech.highWaterSeconds * Constants.Speech.sampleRate / samples.count
        for _ in 0..<blocksAtHighWater { try buffer.append(samples, to: 0) }
        try buffer.finishRequest(0)
        #expect(buffer.reserveRequests().isEmpty)
        #expect(buffer.takePlayableBlocks().count == blocksAtHighWater)
        #expect(buffer.reserveRequests().isEmpty)
        buffer.didPlay(chunkIndex: 0, sampleCount: samples.count)
        #expect(buffer.reserveRequests() == [2])
    }

    @Test
    func underrunRebuffersInsteadOfPlayingEveryTinyArrival() throws {
        var buffer = SpeechBuffer(chunkCount: 2)
        _ = buffer.reserveRequests()
        let startupBlocks = Constants.Speech.startBufferSeconds * Constants.Speech.sampleRate / samples.count
        for _ in 0..<startupBlocks { try buffer.append(samples, to: 0) }
        let playing = buffer.takePlayableBlocks()
        for block in playing { buffer.didPlay(chunkIndex: block.chunkIndex, sampleCount: block.samples.count) }
        #expect(buffer.takePlayableBlocks().isEmpty)
        #expect(!buffer.isPlaying)
        try buffer.append(samples, to: 0)
        #expect(buffer.takePlayableBlocks().isEmpty)
        try buffer.finishRequest(0)
        try buffer.append([0.25], to: 1)
        try buffer.finishRequest(1)
        #expect(buffer.takePlayableBlocks().map(\.chunkIndex) == [0, 1])
        #expect(buffer.isPlaying)
    }

    @Test
    func completionAfterLastPlaybackStillFinishesTheSession() throws {
        var buffer = SpeechBuffer(chunkCount: 1)
        _ = buffer.reserveRequests()
        let count = Constants.Speech.startBufferSeconds * Constants.Speech.sampleRate / samples.count
        for _ in 0..<count { try buffer.append(samples, to: 0) }
        for block in buffer.takePlayableBlocks() { buffer.didPlay(chunkIndex: 0, sampleCount: block.samples.count) }
        #expect(!buffer.isFinished)
        try buffer.finishRequest(0)
        #expect(buffer.takePlayableBlocks().isEmpty)
        #expect(buffer.isFinished)
    }

    @Test
    func enforcesBlockAndPerRequestLimits() throws {
        var buffer = SpeechBuffer(chunkCount: 2)
        _ = buffer.reserveRequests()
        #expect(throws: SpeechError.invalidAudio) { try buffer.append(samples + [0], to: 0) }
        for _ in 0..<(Constants.Speech.maxChunkSamples / samples.count) { try buffer.append(samples, to: 0) }
        #expect(throws: SpeechError.invalidAudio) { try buffer.append([0], to: 0) }
        #expect(throws: SpeechError.invalidAudio) { try buffer.finishRequest(1) }
        #expect(buffer.bufferedSamples == Constants.Speech.maxChunkSamples)
        try buffer.finishRequest(0)
        #expect(throws: SpeechError.invalidAudio) { try buffer.append([0], to: 0) }
    }
}
