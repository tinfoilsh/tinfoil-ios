import Foundation
import Testing
@testable import TinfoilChat

struct SafeguardFlagsTests {
    private static let timestamp = "2026-09-17T12:00:00Z"

    @Test
    func decodesTheFlagsContractAndSortsNewestFirst() throws {
        let report = try decode(flags: [
            ["id": "old", "conversation_id": "chat-a", "created_at": "2026-09-01T12:00:00Z"],
            ["id": "new", "conversation_id": "chat-b", "created_at": "2026-09-17T12:00:00.123456Z"],
            ["id": "unknown", "conversation_id": "", "created_at": "2026-09-10T12:00:00Z"],
        ])

        #expect(report.flags.map(\.id) == ["new", "unknown", "old"])
        #expect(report.flaggedChatIds == Set(["chat-a", "chat-b"]))
        #expect(report.inWindow == 2)
        #expect(report.windowDescription == "7 days")
        #expect(report.progress == 0.2)
        #expect(report.remaining == 8)
    }

    @Test
    func rejectsTheOldEndpointShapeAndMissingPolicy() throws {
        let oldShape = Data(#"{"violations":[],"in_window":0,"window_hours":168,"warn_threshold":8,"ban_threshold":10}"#.utf8)
        let missingPolicy = Data(#"{"flags":[]}"#.utf8)

        #expect(throws: (any Error).self) { try SafeguardFlagsReport.decode(oldShape) }
        #expect(throws: (any Error).self) { try SafeguardFlagsReport.decode(missingPolicy) }
    }

    @Test
    func rejectsInvalidPolicyValuesAndTimestamps() throws {
        for (field, value) in [("in_window", -1), ("window_hours", 0), ("warn_threshold", -1), ("ban_threshold", 0)] {
            #expect(throws: (any Error).self) {
                try decode(overrides: [field: value])
            }
        }
        #expect(throws: (any Error).self) {
            try decode(flags: [["id": "bad", "conversation_id": "chat", "created_at": "not-a-date"]])
        }
    }

    @Test
    func clampsProgressAtTheSuspensionLimit() throws {
        let report = try decode(overrides: ["in_window": 12])
        #expect(report.progress == 1)
        #expect(report.remaining == 0)
        let empty = try decode(overrides: ["in_window": 0])
        #expect(empty.flags.isEmpty)
        #expect(empty.progress == 0)
        #expect(empty.remaining == 10)
    }

    @Test
    func includesTheWindowBoundaryAndKeepsOlderFlags() throws {
        let report = try decode(flags: [
            ["id": "boundary", "conversation_id": "chat-a", "created_at": "2026-09-10T12:00:00Z"],
            ["id": "outside", "conversation_id": "chat-b", "created_at": "2026-09-10T11:59:59Z"],
        ])
        let now = try #require(ISO8601DateFormatter().date(from: Self.timestamp))
        #expect(report.isInWindow(report.flags[0], now: now))
        #expect(!report.isInWindow(report.flags[1], now: now))
        #expect(report.flaggedChatIds.contains("chat-b"))
    }

    @Test
    func formatsServerWindowsWithoutRoundingHoursToDays() throws {
        #expect(try decode(overrides: ["window_hours": 1]).windowDescription == "1 hour")
        #expect(try decode(overrides: ["window_hours": 24]).windowDescription == "1 day")
        #expect(try decode(overrides: ["window_hours": 25]).windowDescription == "25 hours")
    }

    @Test
    func providesChatLinksWithoutInventingMissingIdentifiers() {
        let now = Date()
        let flag = SafeguardFlag(id: "flag", conversationId: "chat-123", createdAt: now)
        #expect(flag.chatURL?.absoluteString == "https://chat.tinfoil.sh/chat/chat-123")
        let unknown = SafeguardFlag(id: "unknown", conversationId: "", createdAt: now)
        #expect(unknown.chatURL == nil)
    }

    private func decode(
        flags: [[String: String]] = [],
        overrides: [String: Int] = [:]
    ) throws -> SafeguardFlagsReport {
        var json: [String: Any] = [
            "flags": flags,
            "in_window": 2,
            "window_hours": 168,
            "warn_threshold": 8,
            "ban_threshold": 10,
        ]
        for (field, value) in overrides { json[field] = value }
        return try SafeguardFlagsReport.decode(JSONSerialization.data(withJSONObject: json))
    }
}
