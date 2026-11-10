import CryptoKit
import Foundation
import Testing
@testable import TinfoilChat

struct DictationStoreTests {
    /// The device's key, which the keychain holds back while the device is
    /// locked and which a new one replaces once the old one is gone.
    private actor DeviceKey: ChatEncryptor {
        private var key = SymmetricKey(size: .bits256)
        private var locked = false

        func encryptData(_ data: Data) async throws -> EncryptedData {
            guard !locked else { throw KeychainError.unavailable }
            return try AESGCMHelper.seal(data, using: key)
        }

        func decryptData(_ encrypted: EncryptedData) async throws -> Data {
            guard !locked else { throw KeychainError.unavailable }
            return try AESGCMHelper.open(encrypted, using: key)
        }

        func lock(_ locked: Bool) {
            self.locked = locked
        }

        func replace() {
            key = SymmetricKey(size: .bits256)
        }
    }

    private static let audio = Data("what the microphone heard".utf8)
    private static let text = "What the microphone heard."

    private func segment(_ index: Int, text: String? = nil) -> DictationStore.Segment {
        DictationStore.Segment(chatId: "chat", dictationId: "dictation", index: index, startedAt: Date(timeIntervalSince1970: TimeInterval(index)), text: text)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    @Test func aRecordingAndItsTextAreKeptSealed() async throws {
        let directory = try temporaryDirectory()
        let store = DictationStore(directory: directory, encryptor: DeviceKey())
        try await store.save(segment(0), audio: Self.audio)
        try await store.save(transcribed: segment(1, text: Self.text))

        let written = try files(in: directory)
        #expect(written.count == 2)
        for url in written {
            let contents = try Data(contentsOf: url)
            #expect(contents.range(of: Self.audio) == nil)
            #expect(contents.range(of: Data(Self.audio.base64EncodedString().utf8)) == nil)
            #expect(contents.range(of: Data(Self.text.utf8)) == nil)
        }
        let kept = await store.load().sorted { $0.segment.index < $1.segment.index }
        #expect(kept.map { $0.segment } == [segment(0), segment(1, text: Self.text)])
        #expect(kept.map { $0.audio } == [Self.audio, nil])
    }

    @Test func aRecordingKeptWhileTheKeyIsUnavailableLoadsOnceItIs() async throws {
        let directory = try temporaryDirectory()
        let key = DeviceKey()
        let store = DictationStore(directory: directory, encryptor: key)
        try await store.save(segment(0), audio: Self.audio)

        await key.lock(true)
        #expect(await store.load().isEmpty)
        #expect(try files(in: directory).count == 1)

        await key.lock(false)
        let kept = await store.load()
        #expect(kept.map { $0.segment } == [segment(0)])
        #expect(kept.first?.audio == Self.audio)
    }

    @Test func aRecordingSealedUnderAKeyThatIsGoneIsRemoved() async throws {
        let directory = try temporaryDirectory()
        let key = DeviceKey()
        let store = DictationStore(directory: directory, encryptor: key)
        try await store.save(segment(0), audio: Self.audio)

        await key.replace()
        #expect(await store.load().isEmpty)
        #expect(try files(in: directory).isEmpty)
    }

    @Test func dictationAnEarlierVersionKeptUnsealedIsSealed() async throws {
        let directory = try temporaryDirectory()
        let waiting = segment(0)
        let transcribed = segment(1, text: Self.text)
        let neverRecorded = segment(2)
        for record in [waiting, transcribed, neverRecorded] {
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.id).appendingPathExtension("json"))
        }
        try Self.audio.write(to: directory.appendingPathComponent(waiting.id).appendingPathExtension(Constants.Audio.recordingFileExtension))
        try Self.audio.write(to: directory.appendingPathComponent("unnamed").appendingPathExtension(Constants.Audio.recordingFileExtension))
        let key = DeviceKey()
        let store = DictationStore(directory: directory, encryptor: key)

        await key.lock(true)
        #expect(await store.load().isEmpty)
        let unsealed = try files(in: directory).map(\.lastPathComponent)
        #expect(Set(unsealed) == [
            "\(waiting.id).json", "\(waiting.id).\(Constants.Audio.recordingFileExtension)", "\(transcribed.id).json",
        ])

        await key.lock(false)
        let kept = await store.load().sorted { $0.segment.index < $1.segment.index }
        #expect(kept.map { $0.segment } == [waiting, transcribed])
        #expect(kept.map { $0.audio } == [Self.audio, nil])
        let left = try files(in: directory)
        #expect(left.count == 2)
        for url in left {
            #expect(url.pathExtension != "json")
            #expect(url.pathExtension != Constants.Audio.recordingFileExtension)
            #expect(try Data(contentsOf: url).range(of: Self.audio) == nil)
        }
    }
}
