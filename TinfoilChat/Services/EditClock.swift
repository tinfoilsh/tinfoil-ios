//
//  EditClock.swift
//  TinfoilChat
//
//  A Lamport-style logical clock shared by mergeable sync units
//  (profile fields, chat rows). Arbitration by `(v, w)` is a total
//  order, making conflict resolution a convergent CRDT LWW-register
//  that is immune to wall-clock skew between devices. Mirrors
//  `services/cloud/edit-clock.ts` in the webapp.
//

import Foundation

/// Per-unit logical edit clock: `v` is a Lamport counter, `w` the
/// writing device id used as a deterministic tiebreak.
struct EditClock: Codable, Equatable {
    let v: Int
    let w: String
}

/// Persisted Lamport counter and stable device id backing the edit
/// clock. The device id is only a tiebreak label, never a secret.
enum EditClockStore {
    private static let deviceIdKey = "tinfoil-sync-device-id"
    private static let counterKey = "tinfoil-sync-edit-clock"

    /// Upper bound for the logical counter. Far above any value a
    /// legitimate edit history could reach, yet with ample headroom
    /// below Int.max so incrementing can never overflow and trap, even
    /// when a corrupted or hostile remote blob carries an absurd clock.
    /// Matches the webapp's JS safe-integer ceiling so both platforms
    /// clamp identically.
    static let maxCounter = 9_007_199_254_740_991  // 2^53 - 1

    private static var defaults: UserDefaults { .standard }

    /// Stable id for this installation. Generated once and persisted.
    static func deviceId() -> String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let next = UUID().uuidString.lowercased()
        defaults.set(next, forKey: deviceIdKey)
        return next
    }

    private static func loadCounter() -> Int {
        let value = defaults.integer(forKey: counterKey)
        guard value > 0 else { return 0 }
        // Clamp a previously-persisted value too, so a counter poisoned
        // before this guard existed self-heals instead of trapping.
        return min(value, maxCounter)
    }

    private static func persistCounter(_ value: Int) {
        defaults.set(value, forKey: counterKey)
    }

    /// Advance the local counter past an observed remote value without
    /// producing a new tick, so a later local edit outranks it. Remote
    /// values are untrusted input (decrypted blob), so a value above the
    /// ceiling is treated as malformed and ignored rather than allowed
    /// to poison the counter toward an overflow.
    static func observe(_ remoteV: Int?) {
        guard let remoteV = remoteV, remoteV > 0, remoteV <= maxCounter else { return }
        if remoteV > loadCounter() {
            persistCounter(remoteV)
        }
    }

    /// Produce the next clock for a local edit, advancing past
    /// `observedMax` (e.g. the unit's current clock) so a re-edit of an
    /// already-high unit still moves forward. The base is clamped to the
    /// ceiling so the increment can never overflow Int and trap.
    static func nextClock(observedMax: Int? = nil) -> EditClock {
        let base = min(max(loadCounter(), observedMax ?? 0), maxCounter)
        let next = min(base + 1, maxCounter)
        persistCounter(next)
        return EditClock(v: next, w: deviceId())
    }
}
