import Foundation
import Testing
@testable import TinfoilChat

struct PCMStreamDecoderTests {
    @Test
    func decodesSignedLittleEndianSamplesAcrossEveryByteSplit() throws {
        let bytes = Data([0x00, 0x80, 0xff, 0xff, 0x00, 0x00, 0x01, 0x00, 0xff, 0x7f])
        let scale = Float(Int16.max) + 1
        let expected = [Int16.min, -1, 0, 1, Int16.max].map { Float($0) / scale }
        for split in 0...bytes.count {
            var decoder = PCMStreamDecoder()
            var samples = try decoder.decode(bytes.prefix(split)).flatMap { $0 }
            samples += try decoder.decode(bytes.dropFirst(split)).flatMap { $0 }
            samples += try decoder.finish()
            #expect(samples == expected)
            #expect(decoder.receivedBytes == bytes.count)
        }
    }

    @Test
    func emitsFullBlocksBeforeTheStreamFinishes() throws {
        let tailCount = 3
        let count = Constants.Speech.blockSamples + tailCount
        var decoder = PCMStreamDecoder()
        let blocks = try decoder.decode(Data(repeating: 0, count: count * Constants.Speech.bytesPerSample))
        #expect(blocks.count == 1)
        #expect(blocks.first?.count == Constants.Speech.blockSamples)
        #expect(try decoder.finish() == [Float](repeating: 0, count: tailCount))
    }

    @Test
    func completesBlocksAcrossNetworkChunksWithoutLosingTheNextSample() throws {
        var decoder = PCMStreamDecoder()
        let prefixSamples = Constants.Speech.blockSamples - 1
        let prefix = try decoder.decode(Data(repeating: 0, count: prefixSamples * Constants.Speech.bytesPerSample))
        #expect(prefix.isEmpty)
        let blocks = try decoder.decode(Data([0x00, 0x80, 0xff]))
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block == [Float](repeating: 0, count: prefixSamples) + [-1])
        #expect(try decoder.decode(Data([0x7f])).isEmpty)
        #expect(try decoder.finish() == [Float(Int16.max) / (Float(Int16.max) + 1)])
    }

    @Test
    func rejectsEmptyAndTruncatedAudio() throws {
        var empty = PCMStreamDecoder()
        #expect(throws: SpeechError.invalidAudio) { try empty.finish() }
        var truncated = PCMStreamDecoder()
        _ = try truncated.decode(Data([0x01, 0x00, 0xff]))
        #expect(throws: SpeechError.invalidAudio) { try truncated.finish() }
    }

    @Test
    func rejectsAnOversizedResponseBeforeAllocatingSampleBlocks() {
        var decoder = PCMStreamDecoder()
        let count = Constants.Speech.maxChunkSamples * Constants.Speech.bytesPerSample + 1
        #expect(throws: SpeechError.invalidAudio) { try decoder.decode(Data(repeating: 0, count: count)) }
        #expect(decoder.receivedBytes == 0)
    }
}
