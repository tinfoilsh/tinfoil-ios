import Foundation

/// When this device last read what the harness stores of the account's
/// chats, and whether its latest attempt failed. Kept apart from the
/// account, which the chat views follow, so that the regular checks redraw
/// only the settings that show it.
@MainActor
final class CloudSyncStatus: ObservableObject {
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var failing = false

    func reportSynced(at date: Date = Date()) {
        lastSyncedAt = date
        if failing { failing = false }
    }

    /// The harness could not be reached. The last time it was stays shown.
    func reportFailed() {
        if !failing { failing = true }
    }

    func reset() {
        if lastSyncedAt != nil { lastSyncedAt = nil }
        if failing { failing = false }
    }
}
