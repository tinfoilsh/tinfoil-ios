//
//  ChatDeletesWatermark.swift
//  TinfoilChat
//
//  Durable cursor for the remote-deletion reconciliation pass, persisted
//  in UserDefaults. It records the server timestamp up to which chat
//  tombstones have been fetched AND applied locally.
//
//  Deliberately independent from the sync-status cache: that cache is a
//  disposable freshness snapshot (cleared on account change, cache
//  misses) that advances whenever any sync pass completes. Reusing its
//  `lastUpdated` as the deletion cursor meant a single skipped or failed
//  deletion pass permanently hid the missed tombstones, leaving deleted
//  chats resurrectable on this device. Mirrors
//  `services/cloud/chat-deletes-watermark.ts` in the webapp.
//

import Foundation

enum ChatDeletesWatermark {
    /// Seed for devices with no persisted watermark. The first pass
    /// replays every retained tombstone, which is idempotent:
    /// already-deleted chats are absent locally and only refresh the
    /// in-memory tracker.
    static let epoch = "1970-01-01T00:00:00.000Z"

    /// Safety overlap subtracted from the newest observed server
    /// timestamp before persisting. Tombstones written concurrently with
    /// a pass (same-millisecond ties, replication lag) are re-listed by
    /// the next pass instead of being skipped; re-applying a tombstone is
    /// a no-op.
    static let overlapSeconds: TimeInterval = 5

    private static var storageKey: String {
        Constants.StorageKeys.Sync.chatDeletesWatermark
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func load(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: storageKey),
           formatter.date(from: stored) != nil {
            return stored
        }
        return epoch
    }

    /// Persist a new watermark derived from the newest event timestamp
    /// observed in a fully reconciled pass. Monotonic: a stale candidate
    /// (overlap window, concurrent passes) never regresses the stored
    /// value.
    static func advance(latestEventAt: Date, defaults: UserDefaults = .standard) {
        let candidate = latestEventAt.addingTimeInterval(-overlapSeconds)
        if let current = formatter.date(from: load(defaults: defaults)),
           candidate <= current {
            return
        }
        defaults.set(
            formatter.string(from: candidate),
            forKey: storageKey
        )
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
