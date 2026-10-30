import Foundation

/// The audio of one message as it streams, scheduled block by block.
/// Playback starts once enough audio has arrived to keep going, or the
/// stream has ended, and rebuffers after an underrun rather than playing
/// every tiny arrival. Scheduled audio counts as buffered until the device
/// has actually played it.
struct SpeechBuffer: Sendable {
    private var blocks: [[Float]] = []
    private var queuedSamples = 0
    private var pendingBuffers = 0
    private(set) var receivedSamples = 0
    private(set) var bufferedSamples = 0
    private(set) var scheduledSamples = 0
    private(set) var isComplete = false
    private(set) var isPlaying = false

    /// Every sample arrived and was played.
    var isFinished: Bool { isComplete && blocks.isEmpty && pendingBuffers == 0 }

    /// Enough audio waits to play that the stream should not be read
    /// further.
    var isFull: Bool { bufferedSamples >= Constants.Speech.maxBufferedSamples }

    mutating func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard !isComplete, samples.count <= Constants.Speech.blockSamples else {
            throw SpeechError.invalidAudio
        }
        blocks.append(samples)
        queuedSamples += samples.count
        receivedSamples += samples.count
        bufferedSamples += samples.count
    }

    /// The stream ended. One that carried no audio is not one this client
    /// plays.
    mutating func finish() throws {
        guard !isComplete, receivedSamples > 0 else { throw SpeechError.invalidAudio }
        isComplete = true
    }

    /// The blocks to schedule now: all that wait, once playback is on.
    mutating func takePlayableBlocks() -> [[Float]] {
        if scheduledSamples == 0 { isPlaying = false }
        if !isPlaying, queuedSamples > 0,
           queuedSamples >= Constants.Speech.startBufferSeconds * Constants.Speech.sampleRate || isComplete {
            isPlaying = true
        }
        guard isPlaying else { return [] }
        let taken = blocks
        pendingBuffers += taken.count
        scheduledSamples += queuedSamples
        blocks = []
        queuedSamples = 0
        return taken
    }

    mutating func didPlay(sampleCount: Int) {
        guard pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        scheduledSamples -= sampleCount
        bufferedSamples -= sampleCount
    }
}
