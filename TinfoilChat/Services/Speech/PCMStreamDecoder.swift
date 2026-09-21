import Foundation

struct PCMStreamDecoder {
    private var lowByte: UInt8?
    private var pendingSamples: [Float] = []
    private(set) var receivedBytes = 0

    mutating func decode(_ data: Data) throws -> [[Float]] {
        let maximumBytes = Constants.Speech.maxChunkSamples * Constants.Speech.bytesPerSample
        guard data.count <= maximumBytes - receivedBytes else { throw SpeechError.invalidAudio }
        receivedBytes += data.count
        var blocks: [[Float]] = []
        for byte in data {
            guard let lowByte else {
                self.lowByte = byte
                continue
            }
            let bits = UInt16(lowByte) | (UInt16(byte) << UInt8.bitWidth)
            pendingSamples.append(Float(Int16(bitPattern: bits)) / Constants.Speech.pcmScale)
            self.lowByte = nil
            if pendingSamples.count == Constants.Speech.blockSamples {
                blocks.append(pendingSamples)
                pendingSamples = []
            }
        }
        return blocks
    }

    mutating func finish() throws -> [Float] {
        guard receivedBytes > 0, lowByte == nil else { throw SpeechError.invalidAudio }
        let samples = pendingSamples
        pendingSamples = []
        return samples
    }
}
