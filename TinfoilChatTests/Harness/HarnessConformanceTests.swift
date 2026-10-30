import Foundation
import Testing
@testable import TinfoilChat

/// The runs the harness recorded, which every client replays: applying a
/// run's frames in order must show what the recording expects.
@Suite("Recorded harness runs")
struct HarnessConformanceTests {
    /// The members of a reply's step the recordings name.
    private static let stepMembers = ["id", "type", "content", "toolCallId", "name", "arguments", "complete", "result", "progress", "display"]

    @Test func areVendored() throws {
        #expect(try HarnessProtocolFixtures.recordedRuns().count > 0)
    }

    @Test(arguments: try HarnessProtocolFixtures.recordedRuns())
    func showsWhatTheRecordingExpects(run: HarnessProtocolFixtures.RecordedRun) throws {
        let state = try run.frames.reduce(ChatState()) { try ChatReducer.reduce($0, $1) }
        let shown = try Self.projection(of: state)
        #expect(shown == NSDictionary(dictionary: run.expected), "\(run.name): \(run.description)")
    }

    /// What the recording names of a chat's state, as JSON.
    private static func projection(of state: ChatState) throws -> NSDictionary {
        let encoder = JSONEncoder()
        var projection: [String: Any] = [
            "status": state.status == .error ? "error" : "idle",
            "messages": try state.messages.map { message -> [String: Any] in
                var shown: [String: Any] = ["id": message.id, "role": message.role.value1?.rawValue ?? ""]
                if message.role.value1 == .user { shown["content"] = message.content ?? "" }
                shown["timeline"] = try (message.timeline ?? []).map { step -> [String: Any] in
                    let all = try JSONSerialization.jsonObject(with: encoder.encode(step)) as! [String: Any]
                    return all.filter { stepMembers.contains($0.key) }
                }
                return shown
            },
        ]
        if let thread = state.snapshot.thread {
            projection["title"] = thread.title
            projection["titleState"] = thread.titleState.value1?.rawValue ?? ""
        }
        if let error = state.error {
            var shown: [String: Any] = ["code": error.code, "message": error.message, "action": error.action.rawValue]
            if let kind = error.kind { shown["kind"] = kind }
            if let retryAfter = error.retryAfter { shown["retryAfter"] = retryAfter }
            if let resetsAt = error.resetsAt { shown["resetsAt"] = resetsAt }
            if let status = error.status { shown["status"] = status }
            if let keyId = error.keyId { shown["keyId"] = keyId }
            if let upstreamCode = error.upstreamCode { shown["upstreamCode"] = upstreamCode }
            if let rateLimit = error.rateLimit {
                shown["rateLimit"] = try JSONSerialization.jsonObject(with: encoder.encode(rateLimit))
            }
            projection["error"] = shown
        }
        // A round trip through JSON compares numbers and nested values as the
        // recording's reader sees them.
        return try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: projection)) as! NSDictionary
    }
}
