//
//  SyncHealthStore.swift
//  TinfoilChat
//
//  The single place where sync failures become user-visible state.
//
//  The upload recovery path used to post `tinfoil.sync.*`
//  notifications that nothing observed, so every terminal failure
//  was invisible. It now reports into this store instead, and the
//  UI (the Cloud Sync settings status row, the sidebar settings
//  badge, the per-chat "couldn't sync" icon) observes it.
//
//  State model:
//   - `gate` is the account-wide condition. `actionRequired` (key
//     problems, blocked account) outranks `paused` (attestation /
//     network trouble that retries itself); a paused report never
//     downgrades an actionRequired gate.
//   - `failedChats` tracks per-chat terminal upload failures; an
//     entry clears when that chat finally uploads or is deleted.
//

import Foundation

@MainActor
final class SyncHealthStore: ObservableObject {
    static let shared = SyncHealthStore()

    enum PausedReason: Equatable {
        case attestation
        case network
    }

    enum ActionReason: Equatable {
        case keyRecovery
        case keyMismatch
        case keyConflict
        case accountBlocked
    }

    enum Gate: Equatable {
        case ok
        case paused(reason: PausedReason, since: Date)
        case actionRequired(reason: ActionReason, since: Date)
    }

    @Published private(set) var gate: Gate = .ok
    /// chatId -> short human-readable failure description.
    @Published private(set) var failedChats: [String: String] = [:]

    private init() {}

    /// The local key cannot write (stale after a rotation, unknown to
    /// the enclave, or colliding with data under another key) or the
    /// account is blocked. Requires a user-driven fix, so it sticks
    /// until `reportKeyHealthy` confirms the key validates again.
    func reportKeyActionRequired(_ reason: ActionReason) {
        if case .actionRequired(let current, _) = gate, current == reason {
            return
        }
        gate = .actionRequired(reason: reason, since: Date())
    }

    /// Sync is blocked by something that retries itself (attestation
    /// failure, network trouble). Never downgrades an actionRequired
    /// gate: a key problem stays the headline until it is fixed.
    func reportSyncPaused(_ reason: PausedReason) {
        if case .actionRequired = gate { return }
        if case .paused(let current, _) = gate, current == reason {
            return
        }
        gate = .paused(reason: reason, since: Date())
    }

    /// The enclave confirmed the local key is the registered current
    /// key. Clears any gate — reaching that verdict required a healthy
    /// enclave round trip, so a paused gate is stale too.
    func reportKeyHealthy() {
        if gate != .ok {
            gate = .ok
        }
    }

    func reportChatSyncFailed(_ chatId: String, message: String) {
        if failedChats[chatId] == message { return }
        failedChats[chatId] = message
    }

    /// Clears a chat's failure entry (successful upload or deletion).
    func reportChatSynced(_ chatId: String) {
        if failedChats[chatId] != nil {
            failedChats.removeValue(forKey: chatId)
        }
    }

    /// Full reset (sign-out).
    func reset() {
        if gate != .ok { gate = .ok }
        if !failedChats.isEmpty { failedChats = [:] }
    }

    /// Whether the current state deserves the attention badge on the
    /// settings entry point: a key problem, a chat that cannot sync,
    /// or a pause that has outlived the self-healing window.
    func needsAttention(now: Date = Date()) -> Bool {
        switch gate {
        case .actionRequired:
            return true
        case .paused(_, let since):
            if now.timeIntervalSince(since) >= Constants.Sync.pausedAttentionWindowSeconds {
                return true
            }
        case .ok:
            break
        }
        return !failedChats.isEmpty
    }
}
