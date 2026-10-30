import Foundation
import Testing
@testable import TinfoilChat

@Suite("Saved prompts")
struct SavedPromptTests {
    /// Prompts as other clients wrote them: dates as strings, and members
    /// this client does not read.
    private let stored: [[String: Any]] = [
        [
            "id": "user:a", "name": "Brief", "systemPrompt": "Be brief.", "model": "gpt-oss-120b",
            "createdAt": "2026-01-02T03:04:05Z", "updatedAt": "2026-01-02T03:04:05Z", "icon": "pencil",
        ],
        [
            "id": "user:b", "name": "Thorough", "createdAt": "2026-02-01T00:00:00.000Z", "updatedAt": 1_767_225_600_000,
            "tags": ["work"],
        ],
    ]

    @Test func anEditRewritesOnlyThePromptItChanges() throws {
        let updated = ProfileManager.updatingPreset("user:a", in: stored, with: [
            "name": "Short",
            "description": "",
            "systemPrompt": "Be short.",
            "model": nil,
            "webSearchEnabled": true,
            "updatedAt": 1_767_312_000_000.0,
        ])

        #expect(updated.count == 2)
        let untouched = try #require(updated[1] as? [String: Any])
        #expect(NSDictionary(dictionary: untouched) == NSDictionary(dictionary: stored[1]))

        let edited = try #require(updated[0] as? [String: Any])
        #expect(edited["name"] as? String == "Short")
        #expect(edited["systemPrompt"] as? String == "Be short.")
        #expect(edited["webSearchEnabled"] as? Bool == true)
        #expect(edited["updatedAt"] as? Double == 1_767_312_000_000)
        #expect(edited["model"] == nil)
        #expect(edited["createdAt"] as? String == "2026-01-02T03:04:05Z")
        #expect(edited["icon"] as? String == "pencil")
    }
}
