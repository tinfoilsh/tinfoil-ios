import Foundation
@testable import TinfoilChat

/// The protocol copy at harness-protocol/, read from the repository this
/// test file is in.
enum HarnessProtocolFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("harness-protocol")

    static var document: String {
        get throws { try String(contentsOf: directory.appendingPathComponent("openapi.yaml"), encoding: .utf8) }
    }

    /// A run the harness recorded, with the chat a client that applies its
    /// frames in order must show.
    struct RecordedRun {
        let name: String
        let description: String
        let frames: [Frame]
        let expected: [String: Any]
    }

    static func recordedRuns() throws -> [RecordedRun] {
        let fixtures = directory.appendingPathComponent("fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".json") }.sorted()
        return try names.map { name in
            let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
            let run = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let frames = try (run["frames"] as! [[String: Any]]).map { frame -> Frame in
                let event = try JSONSerialization.data(withJSONObject: frame["event"]!)
                return try HarnessEventStream.decode([UInt8](event), id: frame["id"] as? Int)!
            }
            return RecordedRun(
                name: name,
                description: run["description"] as! String,
                frames: frames,
                expected: run["expected"] as! [String: Any]
            )
        }
    }

    /// One frame's event, as a test writes it.
    static func frame(_ event: [String: Any], id: Int? = nil) throws -> Frame {
        try HarnessEventStream.decode([UInt8](JSONSerialization.data(withJSONObject: event)), id: id)!
    }
}
