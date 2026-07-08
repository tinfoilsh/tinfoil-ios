//
//  ProfileMerge.swift
//  TinfoilChat
//
//  Field-level conflict resolution for profile sync. Mirrors
//  `services/cloud/profile-merge.ts` in the webapp: each field is
//  arbitrated by its edit clock when both sides are trusted (a
//  convergent CRDT LWW-register, immune to clock skew), falling back to
//  whole-blob updatedAt when a clock is absent or untrusted, and never
//  letting an empty/default blob wipe a populated profile on fallback.
//

import Foundation

enum ProfileMerge {
    /// User-facing fields that participate in the merge. Metadata
    /// (version, updatedAt, clocks) is handled separately.
    static let mergeFields: [String] = [
        "isDarkMode", "themeMode", "language", "nickname", "profession",
        "traits", "additionalContext", "isUsingPersonalization",
        "isUsingCustomPrompt", "customSystemPrompt", "customPromptPresets",
        "favoritePromptPresetIds", "reasoningEffort",
        "thinkingEnabled", "webSearchEnabled", "codeExecutionEnabled",
        "piiCheckEnabled", "genUIEnabled", "chatFont",
        "projectUploadPreference",
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    // A blob's field clocks are trustworthy only when maintained at the
    // row's current server version.
    private static func clocksTrusted(_ p: ProfileData) -> Bool {
        guard let clockVersion = p.clockVersion, let version = p.version else {
            return false
        }
        return clockVersion == version
    }

    /// True when the profile carries user content worth protecting.
    static func isProfilePopulated(_ p: ProfileData?) -> Bool {
        guard let p = p else { return false }
        func nonEmpty(_ s: String?) -> Bool {
            guard let s = s else { return false }
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if nonEmpty(p.nickname) || nonEmpty(p.profession)
            || nonEmpty(p.additionalContext) || nonEmpty(p.customSystemPrompt) {
            return true
        }
        if let traits = p.traits, !traits.isEmpty { return true }
        if let presets = p.customPromptPresets, !presets.isEmpty { return true }
        if let favs = p.favoritePromptPresetIds, !favs.isEmpty { return true }
        return false
    }

    /// Field names whose local value differs from the last-synced
    /// baseline, derived by diffing values rather than tracking events.
    static func changedProfileFields(
        local: ProfileData, baseline: ProfileData?
    ) -> [String] {
        guard let baseline = baseline else { return mergeFields }
        let localDict = (try? dictionary(from: local)) ?? [:]
        let baselineDict = (try? dictionary(from: baseline)) ?? [:]
        var changed: [String] = []
        for field in mergeFields {
            let a = localDict[field]
            let b = baselineDict[field]
            if !valuesEqual(a, b) {
                changed.append(field)
            }
        }
        return changed
    }

    /// Merge a remote profile into the local one field by field.
    static func mergeProfiles(
        local: ProfileData, remote: ProfileData
    ) -> (merged: ProfileData, adoptedRemote: Bool) {
        let localTrusted = clocksTrusted(local)
        let remoteTrusted = clocksTrusted(remote)
        let fallback = !(localTrusted && remoteTrusted)

        // On the fallback path there is no per-field signal to trust, so
        // a single empty/default remote could clobber every populated
        // local field at once (the data-loss incident). Refuse it.
        if fallback && !isProfilePopulated(remote) && isProfilePopulated(local) {
            return (local, false)
        }

        let localUpdatedAt = parseDate(local.updatedAt)
        let remoteUpdatedAt = parseDate(remote.updatedAt)

        guard
            var mergedDict = try? dictionary(from: local),
            let remoteDict = try? dictionary(from: remote)
        else {
            return (local, false)
        }

        // Build the merged clocks from scratch, carrying only clocks we
        // actually trust. Seeding from local.fieldClocks would smuggle
        // untrusted/stale clocks into the output, which the next push
        // re-stamps as trusted (clockVersion == version) and corrupts
        // future conflict resolution.
        var mergedClocks: [String: EditClock] = [:]
        var adoptedRemote = false

        for field in mergeFields {
            let lc = localTrusted ? local.fieldClocks?[field] : nil

            // Remote omits this field: keep the local value and its
            // clock, but only when the local clock is trusted.
            guard remoteDict[field] != nil else {
                if let lc = lc { mergedClocks[field] = lc }
                continue
            }

            let rc = remoteTrusted ? remote.fieldClocks?[field] : nil
            let takeRemote = SyncConflictResolver.remoteWins(
                localClock: lc,
                remoteClock: rc,
                localUpdatedAt: localUpdatedAt,
                remoteUpdatedAt: remoteUpdatedAt
            )
            if takeRemote {
                mergedDict[field] = remoteDict[field]
                // Record a clock for the adopted value only if the remote
                // clock is trusted; otherwise leave it absent so future
                // reads fall back to updatedAt for this field.
                if let rc = rc { mergedClocks[field] = rc }
                adoptedRemote = true
            } else if let lc = lc {
                mergedClocks[field] = lc
            }
        }

        var merged = (try? profile(from: mergedDict)) ?? local
        merged.fieldClocks = mergedClocks.isEmpty ? nil : mergedClocks
        merged.updatedAt = laterTimestamp(local.updatedAt, remote.updatedAt)
        return (merged, adoptedRemote)
    }

    // MARK: - Helpers

    private static func laterTimestamp(_ a: String?, _ b: String?) -> String? {
        let da = parseDate(a)
        let db = parseDate(b)
        guard let da = da else { return b ?? a }
        guard let db = db else { return a }
        return da >= db ? a : b
    }

    private static func dictionary(from profile: ProfileData) throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func profile(from dict: [String: Any]) throws -> ProfileData {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(ProfileData.self, from: data)
    }

    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (x?, y?):
            return NSObject.isEqual(x, to: y)
        default:
            return false
        }
    }
}

private extension NSObject {
    static func isEqual(_ a: Any, to b: Any) -> Bool {
        (a as AnyObject).isEqual(b as AnyObject)
    }
}
