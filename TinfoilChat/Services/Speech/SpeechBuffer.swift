import Foundation

/// Tracks generated and scheduled audio together so scheduling a buffer does not
/// free generation capacity until the device has actually played it.
struct SpeechBuffer: Sendable {
    struct Block: Sendable {
        let chunkIndex: Int
        let samples: [Float]
    }

    private struct Chunk: Sendable {
        var blocks: [[Float]] = []
        var queuedSamples = 0
        var receivedSamples = 0
        var pendingBuffers = 0
        var isComplete = false
    }

    let chunkCount: Int
    private var chunks: [Int: Chunk] = [:]
    private(set) var nextRequest = 0
    private(set) var nextSchedule = 0
    private(set) var nextPlayback = 0
    private(set) var inFlight = 0
    private(set) var bufferedSamples = 0
    private(set) var scheduledSamples = 0
    private(set) var isPlaying = false

    var isFinished: Bool { nextPlayback == chunkCount }

    init(chunkCount: Int) {
        self.chunkCount = chunkCount
    }

    mutating func reserveRequests() -> [Int] {
        var indices: [Int] = []
        while inFlight < Constants.Speech.concurrentRequests,
              nextRequest < chunkCount,
              nextRequest < nextPlayback + Constants.Speech.lookaheadChunks,
              bufferedSamples < Constants.Speech.highWaterSeconds * Constants.Speech.sampleRate {
            let index = nextRequest
            chunks[index] = Chunk()
            nextRequest += 1
            inFlight += 1
            indices.append(index)
        }
        return indices
    }

    mutating func append(_ samples: [Float], to index: Int) throws {
        guard !samples.isEmpty else { return }
        guard var chunk = chunks[index], !chunk.isComplete,
              samples.count <= Constants.Speech.blockSamples,
              samples.count <= Constants.Speech.maxChunkSamples - chunk.receivedSamples,
              samples.count <= Constants.Speech.maxBufferedSamples - bufferedSamples else {
            throw SpeechError.invalidAudio
        }
        chunk.blocks.append(samples)
        chunk.queuedSamples += samples.count
        chunk.receivedSamples += samples.count
        chunks[index] = chunk
        bufferedSamples += samples.count
    }

    mutating func finishRequest(_ index: Int) throws {
        guard var chunk = chunks[index], !chunk.isComplete, chunk.receivedSamples > 0 else {
            throw SpeechError.invalidAudio
        }
        chunk.isComplete = true
        chunks[index] = chunk
        inFlight -= 1
    }

    mutating func takePlayableBlocks() -> [Block] {
        while nextSchedule < nextRequest,
              let chunk = chunks[nextSchedule], chunk.isComplete, chunk.blocks.isEmpty {
            nextSchedule += 1
        }
        retirePlayedChunks()
        if scheduledSamples == 0 { isPlaying = false }

        var contiguousSamples = 0
        var completeChunks = 0
        for index in nextSchedule..<nextRequest {
            guard let chunk = chunks[index] else { break }
            contiguousSamples += chunk.queuedSamples
            if !chunk.isComplete { break }
            completeChunks += 1
        }
        let tailIsReady = completeChunks == chunkCount - nextSchedule
        let windowIsReady = nextRequest == nextPlayback + Constants.Speech.lookaheadChunks
            && nextSchedule + completeChunks == nextRequest
        if !isPlaying, contiguousSamples > 0,
           contiguousSamples >= Constants.Speech.startBufferSeconds * Constants.Speech.sampleRate
            || tailIsReady || windowIsReady {
            isPlaying = true
        }
        guard isPlaying else { return [] }

        var result: [Block] = []
        while nextSchedule < nextRequest, var chunk = chunks[nextSchedule] {
            result.append(contentsOf: chunk.blocks.map { Block(chunkIndex: nextSchedule, samples: $0) })
            chunk.pendingBuffers += chunk.blocks.count
            scheduledSamples += chunk.queuedSamples
            chunk.blocks = []
            chunk.queuedSamples = 0
            chunks[nextSchedule] = chunk
            if !chunk.isComplete { break }
            nextSchedule += 1
        }
        retirePlayedChunks()
        return result
    }

    mutating func didPlay(chunkIndex: Int, sampleCount: Int) {
        guard var chunk = chunks[chunkIndex], chunk.pendingBuffers > 0 else { return }
        chunk.pendingBuffers -= 1
        chunks[chunkIndex] = chunk
        scheduledSamples -= sampleCount
        bufferedSamples -= sampleCount
        retirePlayedChunks()
    }

    private mutating func retirePlayedChunks() {
        while nextPlayback < nextSchedule,
              let chunk = chunks[nextPlayback], chunk.isComplete,
              chunk.pendingBuffers == 0, chunk.blocks.isEmpty {
            chunks.removeValue(forKey: nextPlayback)
            nextPlayback += 1
        }
    }
}
