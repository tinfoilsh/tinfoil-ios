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
struct EditClock: Codable, Equatable, Sendable {
    let v: Int
    let w: String
}

final class EditClockAllocator: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func deviceId() -> String {
        lock.lock()
        defer { lock.unlock() }
        return deviceIdUnlocked()
    }

    func observe(_ remoteV: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard let remoteV, remoteV > 0, remoteV < EditClockStore.maxCounter else { return }
        if remoteV > loadCounterUnlocked() {
            persistCounterUnlocked(remoteV)
        }
    }

    func nextClock(observedMax: Int? = nil) throws -> EditClock {
        lock.lock()
        defer { lock.unlock() }
        let validObservedMax = observedMax.flatMap {
            $0 > 0 && $0 < EditClockStore.maxCounter ? $0 : nil
        } ?? 0
        let base = min(
            max(loadCounterUnlocked(), validObservedMax),
            EditClockStore.maxCounter
        )
        let next = try EditClockStore.incrementedCounter(after: base)
        persistCounterUnlocked(next)
        return EditClock(v: next, w: deviceIdUnlocked())
    }

    private func deviceIdUnlocked() -> String {
        if let existing = defaults.string(forKey: EditClockStore.deviceIdKey), !existing.isEmpty {
            return existing
        }
        let next = UUID().uuidString.lowercased()
        defaults.set(next, forKey: EditClockStore.deviceIdKey)
        return next
    }

    private func loadCounterUnlocked() -> Int {
        let value = defaults.integer(forKey: EditClockStore.counterKey)
        guard value > 0 else { return 0 }
        return min(value, EditClockStore.maxCounter)
    }

    private func persistCounterUnlocked(_ value: Int) {
        defaults.set(value, forKey: EditClockStore.counterKey)
    }
}

struct ChatClockState: Equatable {
    let clock: Int?
    let writer: String?
    let clockVersion: Int?
}

enum ChatEditClockPolicy {
    static func matchesFrozenMutation(
        current: ChatClockState,
        uploaded: ChatClockState
    ) -> Bool {
        current.clock == uploaded.clock && current.writer == uploaded.writer
    }

    static func uploadState(
        clock: Int?,
        writer: String?,
        currentSyncVersion: Int
    ) -> ChatClockState {
        ChatClockState(
            clock: clock,
            writer: writer,
            clockVersion: clock == nil || writer == nil ? nil : currentSyncVersion + 1
        )
    }

    static func finalizedState(
        uploaded: ChatClockState,
        current: ChatClockState,
        authoritativeSyncVersion: Int,
        editedDuringUpload: Bool
    ) -> ChatClockState {
        if editedDuringUpload {
            return ChatClockState(
                clock: current.clock,
                writer: current.writer,
                clockVersion: current.clock == nil || current.writer == nil
                    ? nil : authoritativeSyncVersion + 1
            )
        }
        return ChatClockState(
            clock: uploaded.clock,
            writer: uploaded.writer,
            clockVersion: uploaded.clock == nil || uploaded.writer == nil
                ? nil : authoritativeSyncVersion
        )
    }
}

/// Persisted Lamport counter and stable device id backing the edit
/// clock. The device id is only a tiebreak label, never a secret.
enum EditClockStore {
    enum ClockError: Error {
        case counterExhausted
    }

    fileprivate static let deviceIdKey = "tinfoil-sync-device-id"
    fileprivate static let counterKey = "tinfoil-sync-edit-clock"
    private static let allocator = EditClockAllocator(defaults: .standard)

    /// Upper bound for the logical counter. Far above any value a
    /// legitimate edit history could reach, yet with ample headroom
    /// below Int.max so incrementing can never overflow and trap.
    /// Matches the webapp's JS safe-integer ceiling.
    static let maxCounter = 9_007_199_254_740_991  // 2^53 - 1

    /// Stable id for this installation. Generated once and persisted.
    static func deviceId() -> String {
        allocator.deviceId()
    }

    /// Advance the local counter past an observed remote value without
    /// producing a new tick, so a later local edit outranks it. Remote
    /// values are untrusted input (decrypted blob), so a value at or above
    /// the ceiling is malformed: accepting it would prevent every future
    /// local edit from allocating a distinct tuple.
    static func observe(_ remoteV: Int?) {
        allocator.observe(remoteV)
    }

    static func incrementedCounter(after base: Int) throws -> Int {
        guard base < maxCounter else { throw ClockError.counterExhausted }
        return base + 1
    }

    /// Produce the next clock for a local edit, advancing past
    /// `observedMax` (e.g. the unit's current clock) so a re-edit of an
    /// already-high unit still moves forward. Exhaustion refuses the edit
    /// rather than reusing a tuple that would not be a monotonic tick.
    static func nextClock(observedMax: Int? = nil) throws -> EditClock {
        try allocator.nextClock(observedMax: observedMax)
    }
}
