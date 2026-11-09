import Foundation

/// The dictation an account keeps on this device until its text reaches the
/// composer: each recording until it is transcribed, then its text.
actor DictationStore {
    /// A recording of a dictation in a chat, and its text once transcribed.
    struct Segment: Codable, Equatable, Sendable {
        let chatId: String
        let dictationId: String
        let index: Int
        let startedAt: Date
        var text: String?

        var id: String { "\(dictationId)_\(index)" }
    }

    private static let recordExtension = "json"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    init(userId: String) throws {
        directory = try DictationStore.directory(userId: userId, create: true)
    }

    static func directory(userId: String, create: Bool) throws -> URL {
        let safe = userId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let url = try DeviceDataDirectory.url(create: create)
            .appendingPathComponent("dictation", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        return url
    }

    /// Forgets the dictation the account keeps, as when it signs out.
    static func wipe(userId: String) {
        if let directory = try? directory(userId: userId, create: false) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Keeps a recording until it is transcribed. Its record is written
    /// first, so audio is never kept that no record names; a record whose
    /// audio was not written is forgotten when it is loaded. Neither is
    /// written once the account's directory was wiped.
    func save(_ segment: Segment, audio: Data) throws {
        try JSONEncoder().encode(segment).write(to: recordURL(segment.id), options: [.atomic, .completeFileProtectionUnlessOpen])
        try audio.write(to: audioURL(segment.id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Keeps a recording's text in its place until it reaches the composer.
    func save(transcribed segment: Segment) throws {
        try JSONEncoder().encode(segment).write(to: recordURL(segment.id), options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.removeItem(at: audioURL(segment.id))
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: recordURL(id))
        try? FileManager.default.removeItem(at: audioURL(id))
    }

    /// The recordings kept, with the audio of those not yet transcribed.
    func load() -> [(segment: Segment, audio: Data?)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == Self.recordExtension }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let segment = try? JSONDecoder().decode(Segment.self, from: data) else { return nil }
            let audio = segment.text == nil ? try? Data(contentsOf: audioURL(segment.id)) : nil
            return (segment, audio)
        }
    }

    private func recordURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(Self.recordExtension)
    }

    private func audioURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(Constants.Audio.recordingFileExtension)
    }
}
