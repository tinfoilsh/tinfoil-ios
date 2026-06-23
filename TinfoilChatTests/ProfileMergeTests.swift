//  ProfileMergeTests.swift
//  TinfoilChatTests
//
//  Field-level conflict resolution and clock arbitration for profile
//  sync. Mirrors the webapp's profile-merge / sync-predicate tests.
//

import Foundation
import Testing
@testable import TinfoilChat

@Suite("Profile merge and clock arbitration")
struct ProfileMergeTests {

    private func trusted(_ p: ProfileData) -> ProfileData {
        var copy = p
        copy.version = 10
        copy.clockVersion = 10
        return copy
    }

    @Test("keeps each side's field with the higher clock")
    func keepsHigherClockPerField() {
        var local = ProfileData(
            nickname: "local-name", customSystemPrompt: "old-prompt"
        )
        local.fieldClocks = [
            "nickname": EditClock(v: 5, w: "A"),
            "customSystemPrompt": EditClock(v: 1, w: "A"),
        ]
        local.updatedAt = "2024-01-01T00:00:00.000Z"

        var remote = ProfileData(
            nickname: "remote-name", customSystemPrompt: "new-prompt"
        )
        remote.fieldClocks = [
            "nickname": EditClock(v: 2, w: "B"),
            "customSystemPrompt": EditClock(v: 9, w: "B"),
        ]
        remote.updatedAt = "2024-01-02T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(
            local: trusted(local), remote: trusted(remote)
        )

        #expect(result.merged.nickname == "local-name")
        #expect(result.merged.customSystemPrompt == "new-prompt")
        #expect(result.adoptedRemote == true)
    }

    @Test("converges regardless of merge direction")
    func converges() {
        var local = ProfileData(nickname: "local-name", profession: "old-job")
        local.fieldClocks = [
            "nickname": EditClock(v: 5, w: "A"),
            "profession": EditClock(v: 1, w: "A"),
        ]
        var remote = ProfileData(nickname: "remote-name", profession: "new-job")
        remote.fieldClocks = [
            "nickname": EditClock(v: 2, w: "B"),
            "profession": EditClock(v: 9, w: "B"),
        ]

        let a = ProfileMerge.mergeProfiles(
            local: trusted(local), remote: trusted(remote)
        ).merged
        let b = ProfileMerge.mergeProfiles(
            local: trusted(remote), remote: trusted(local)
        ).merged

        #expect(a.nickname == b.nickname)
        #expect(a.profession == b.profession)
        #expect(a.nickname == "local-name")
        #expect(a.profession == "new-job")
    }

    @Test("refuses to let an empty remote wipe a populated local on fallback")
    func emptyRemoteGuard() {
        var local = ProfileData(
            nickname: "real-user", traits: ["curious"], customSystemPrompt: "my prompt"
        )
        local.updatedAt = "2024-01-01T00:00:00.000Z"
        var remote = ProfileData(nickname: "", traits: [], customSystemPrompt: "")
        remote.updatedAt = "2024-01-02T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(local: local, remote: remote)

        #expect(result.merged.nickname == "real-user")
        #expect(result.merged.customSystemPrompt == "my prompt")
        #expect(result.adoptedRemote == false)
    }

    @Test("does not carry untrusted local clocks into the merged output")
    func dropsUntrustedLocalClocks() {
        var local = ProfileData(nickname: "local", profession: "local-job")
        local.version = 4
        local.clockVersion = 2
        local.fieldClocks = [
            "nickname": EditClock(v: 99, w: "A"),
            "profession": EditClock(v: 99, w: "A"),
        ]
        local.updatedAt = "2024-01-02T00:00:00.000Z"

        var remote = ProfileData(nickname: "remote")
        remote.version = 5
        remote.clockVersion = 2
        remote.fieldClocks = ["nickname": EditClock(v: 1, w: "B")]
        remote.updatedAt = "2024-01-01T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(local: local, remote: remote)

        #expect(result.merged.nickname == "local")
        #expect(result.merged.profession == "local-job")
        // No trusted clock existed for either field, so none is carried.
        #expect(result.merged.fieldClocks == nil)
    }

    @Test("falls back to updatedAt when clocks are untrusted")
    func untrustedFallback() {
        var local = ProfileData(nickname: "local")
        local.version = 4
        local.clockVersion = 2
        local.fieldClocks = ["nickname": EditClock(v: 99, w: "A")]
        local.updatedAt = "2024-01-01T00:00:00.000Z"

        var remote = ProfileData(nickname: "remote")
        remote.version = 5
        remote.clockVersion = 2
        remote.fieldClocks = ["nickname": EditClock(v: 1, w: "B")]
        remote.updatedAt = "2024-01-02T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(local: local, remote: remote)

        #expect(result.merged.nickname == "remote")
    }

    @Test("isProfilePopulated detects user content")
    func populated() {
        #expect(ProfileMerge.isProfilePopulated(ProfileData(nickname: "x")) == true)
        #expect(ProfileMerge.isProfilePopulated(ProfileData(traits: ["a"])) == true)
        #expect(ProfileMerge.isProfilePopulated(nil) == false)
        #expect(
            ProfileMerge.isProfilePopulated(
                ProfileData(nickname: "", traits: [], thinkingEnabled: true)
            ) == false
        )
    }

    @Test("changedProfileFields diffs values")
    func changedFields() {
        let baseline = ProfileData(nickname: "a", traits: ["x"], thinkingEnabled: true)
        let local = ProfileData(nickname: "b", traits: ["x", "y"], thinkingEnabled: true)
        let fields = ProfileMerge.changedProfileFields(local: local, baseline: baseline)
        #expect(Set(fields) == Set(["nickname", "traits"]))
    }
}

@Suite("Clock-aware conflict resolution")
struct EditClockArbitrationTests {

    // Reset the shared counter before each test so cases that push it to
    // the ceiling don't bleed into the monotonicity assertions.
    init() {
        UserDefaults.standard.removeObject(forKey: "tinfoil-sync-edit-clock")
    }

    @Test("ignores remote clock values above the ceiling without trapping")
    func ceilingGuard() {
        // A hostile or corrupt remote clock must not poison the counter
        // into an overflow trap on the next tick.
        EditClockStore.observe(Int.max)
        #expect(EditClockStore.nextClock().v == 1)

        EditClockStore.observe(EditClockStore.maxCounter)
        #expect(EditClockStore.nextClock().v == EditClockStore.maxCounter)
        // A further tick stays pinned at the ceiling rather than trapping.
        #expect(EditClockStore.nextClock().v == EditClockStore.maxCounter)
    }

    @Test("prefers the higher clock counter over wall-clock time")
    func clockBeatsTime() {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        #expect(
            SyncConflictResolver.remoteWins(
                localClock: EditClock(v: 1, w: "a"),
                remoteClock: EditClock(v: 2, w: "a"),
                localUpdatedAt: newer,
                remoteUpdatedAt: older
            ) == true
        )
    }

    @Test("breaks an equal counter by writer id deterministically")
    func writerTiebreak() {
        #expect(
            SyncConflictResolver.remoteWins(
                localClock: EditClock(v: 3, w: "aaa"),
                remoteClock: EditClock(v: 3, w: "bbb"),
                localUpdatedAt: nil, remoteUpdatedAt: nil
            ) == true
        )
        #expect(
            SyncConflictResolver.remoteWins(
                localClock: EditClock(v: 3, w: "bbb"),
                remoteClock: EditClock(v: 3, w: "aaa"),
                localUpdatedAt: nil, remoteUpdatedAt: nil
            ) == false
        )
    }

    @Test("treats an identical clock as the same write")
    func identicalClock() {
        #expect(
            SyncConflictResolver.remoteWins(
                localClock: EditClock(v: 7, w: "a"),
                remoteClock: EditClock(v: 7, w: "a"),
                localUpdatedAt: nil, remoteUpdatedAt: nil
            ) == false
        )
    }

    @Test("falls back to updatedAt when a clock is missing")
    func missingClockFallback() {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        #expect(
            SyncConflictResolver.remoteWins(
                localClock: EditClock(v: 9, w: "a"),
                remoteClock: nil,
                localUpdatedAt: older, remoteUpdatedAt: newer
            ) == true
        )
    }

    @Test("the edit clock counter is strictly increasing and observes remotes")
    func counterMonotonic() {
        let a = EditClockStore.nextClock()
        let b = EditClockStore.nextClock()
        #expect(b.v > a.v)
        EditClockStore.observe(b.v + 1000)
        #expect(EditClockStore.nextClock().v > b.v + 1000)
    }
}
