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

    @Test("pins-only remote cannot bypass the destructive fallback guard")
    func pinsOnlyRemoteGuard() {
        var local = ProfileData(nickname: "real-user", profession: "Engineer")
        local.updatedAt = "2024-01-01T00:00:00.000Z"
        var remote = ProfileData(pinnedChatIds: ["chat-a"])
        remote.updatedAt = "2024-01-02T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(local: local, remote: remote)

        #expect(result.merged.nickname == "real-user")
        #expect(result.merged.profession == "Engineer")
        #expect(result.adoptedRemote == false)
    }

    @Test("preset favorites-only remote cannot bypass the fallback guard")
    func presetFavoritesOnlyRemoteGuard() {
        var local = ProfileData(customSystemPrompt: "Keep this")
        local.updatedAt = "2024-01-01T00:00:00.000Z"
        var remote = ProfileData(favoritePromptPresetIds: ["preset-a"])
        remote.updatedAt = "2024-01-02T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(local: local, remote: remote)

        #expect(result.merged.customSystemPrompt == "Keep this")
        #expect(result.adoptedRemote == false)
    }

    @Test("fallback explicit clear does not wipe pins-only local content")
    func pinsOnlyFallbackClearGuard() {
        var local = ProfileData(pinnedChatIds: ["chat-a"])
        local.updatedAt = "2024-01-01T00:00:00.000Z"
        var remote = ProfileData(pinnedChatIds: [])
        remote.updatedAt = "2024-01-02T00:00:00.000Z"

        let result = ProfileMerge.mergeProfiles(local: local, remote: remote)

        #expect(result.merged.pinnedChatIds == ["chat-a"])
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
        #expect(ProfileMerge.isProfilePopulated(ProfileData(pinnedChatIds: ["chat-a"])) == true)
        #expect(ProfileMerge.isProfilePopulated(ProfileData(favoritePromptPresetIds: ["preset-a"])) == true)
        #expect(ProfileMerge.isProfilePopulated(nil) == false)
        #expect(
            ProfileMerge.isProfilePopulated(
                ProfileData(nickname: "", traits: [], thinkingEnabled: true)
            ) == false
        )
    }

    @Test("changedProfileFields diffs values")
    func changedFields() {
        let baseline = ProfileData(
            nickname: "a",
            traits: ["x"],
            thinkingEnabled: true,
            webSearchAvailable: true,
            piiCheckEnabled: true
        )
        let local = ProfileData(
            nickname: "b",
            traits: ["x", "y"],
            thinkingEnabled: true,
            webSearchAvailable: false,
            piiCheckEnabled: false
        )
        let fields = ProfileMerge.changedProfileFields(local: local, baseline: baseline)
        #expect(Set(fields) == Set(["nickname", "traits", "webSearchAvailable", "piiCheckEnabled"]))
    }

    @Test("PII setting uses the higher trusted field clock")
    func mergesPIISettingByClock() {
        var local = ProfileData(piiCheckEnabled: true)
        local.fieldClocks = ["piiCheckEnabled": EditClock(v: 1, w: "A")]
        var remote = ProfileData(piiCheckEnabled: false)
        remote.fieldClocks = ["piiCheckEnabled": EditClock(v: 2, w: "B")]

        let result = ProfileMerge.mergeProfiles(
            local: trusted(local), remote: trusted(remote)
        )

        #expect(result.merged.piiCheckEnabled == false)
        #expect(result.merged.fieldClocks?["piiCheckEnabled"] == EditClock(v: 2, w: "B"))
    }

    @Test("dirty profile without baseline preserves local pins and remote settings")
    func reconcilesPinnedChatsWithoutBaseline() throws {
        let local = ProfileData(
            themeMode: "light",
            nickname: "Remote",
            profession: "Researcher",
            pinnedChatIds: ["chat-a"]
        )
        var remote = ProfileData(
            themeMode: "light",
            nickname: "Remote",
            profession: "Researcher"
        )
        remote.version = 4

        let reconciled = try #require(
            ProfileMerge.reconcileDirtyProfileWithoutBaseline(
                local: local,
                remote: remote
            )
        )

        #expect(reconciled.themeMode == "light")
        #expect(reconciled.nickname == "Remote")
        #expect(reconciled.profession == "Researcher")
        #expect(reconciled.pinnedChatIds == ["chat-a"])
        #expect(reconciled.version == 4)
    }

    @Test("dirty profile without baseline preserves an explicit pin clear")
    func reconcilesExplicitPinnedChatClearWithoutBaseline() throws {
        let reconciled = try #require(
            ProfileMerge.reconcileDirtyProfileWithoutBaseline(
                local: ProfileData(pinnedChatIds: []),
                remote: ProfileData(
                    nickname: "Remote",
                    pinnedChatIds: ["remote-chat"]
                )
            )
        )

        #expect(reconciled.nickname == "Remote")
        #expect(reconciled.pinnedChatIds == [])
    }

    @Test("dirty profile without baseline accepts matching remote pins")
    func acceptsMatchingPinnedChatsWithoutBaseline() throws {
        let reconciled = try #require(
            ProfileMerge.reconcileDirtyProfileWithoutBaseline(
                local: ProfileData(nickname: "Remote", pinnedChatIds: ["chat-a"]),
                remote: ProfileData(nickname: "Remote", pinnedChatIds: ["chat-a"])
            )
        )

        #expect(reconciled.pinnedChatIds == ["chat-a"])
    }

    @Test("dirty profile without baseline ignores omitted local defaults")
    func reconcilesPinnedChatsWithOmittedDefaults() throws {
        let reconciled = try #require(
            ProfileMerge.reconcileDirtyProfileWithoutBaseline(
                local: ProfileData(
                    isDarkMode: ProfileDefaults.isDarkMode,
                    language: ProfileDefaults.language,
                    isUsingPersonalization: ProfileDefaults.isUsingPersonalization,
                    reasoningEffort: ProfileDefaults.reasoningEffort,
                    thinkingEnabled: ProfileDefaults.thinkingEnabled,
                    webSearchAvailable: ProfileDefaults.webSearchAvailable,
                    piiCheckEnabled: ProfileDefaults.piiCheckEnabled,
                    genUIEnabled: ProfileDefaults.genUIEnabled,
                    pinnedChatIds: ["chat-a"]
                ),
                remote: ProfileData(
                    webSearchAvailable: !ProfileDefaults.webSearchAvailable
                )
            )
        )

        #expect(reconciled.webSearchAvailable == !ProfileDefaults.webSearchAvailable)
        #expect(reconciled.isDarkMode == nil)
        #expect(reconciled.language == nil)
        #expect(reconciled.isUsingPersonalization == nil)
        #expect(reconciled.reasoningEffort == nil)
        #expect(reconciled.thinkingEnabled == nil)
        #expect(reconciled.piiCheckEnabled == nil)
        #expect(reconciled.genUIEnabled == nil)
        #expect(reconciled.pinnedChatIds == ["chat-a"])
    }

    @Test("dirty profile without baseline rejects ambiguous changes")
    func rejectsAmbiguousChangesWithoutBaseline() {
        let missingLocal = ProfileMerge.reconcileDirtyProfileWithoutBaseline(
            local: ProfileData(nickname: "Local"),
            remote: ProfileData(nickname: "Remote")
        )
        let conflictingSetting = ProfileMerge.reconcileDirtyProfileWithoutBaseline(
            local: ProfileData(nickname: "Local", pinnedChatIds: ["chat-a"]),
            remote: ProfileData(nickname: "Remote")
        )
        let localOnlySetting = ProfileMerge.reconcileDirtyProfileWithoutBaseline(
            local: ProfileData(
                nickname: "Remote",
                profession: "Researcher",
                pinnedChatIds: ["chat-a"]
            ),
            remote: ProfileData(nickname: "Remote")
        )
        #expect(missingLocal == nil)
        #expect(conflictingSetting == nil)
        #expect(localOnlySetting == nil)
    }

    @Test("dirty profile without baseline combines divergent pins")
    func combinesDivergentPinsWithoutBaseline() throws {
        let reconciled = try #require(
            ProfileMerge.reconcileDirtyProfileWithoutBaseline(
                local: ProfileData(pinnedChatIds: ["local-chat", "shared-chat"]),
                remote: ProfileData(pinnedChatIds: ["remote-chat", "shared-chat"])
            )
        )

        #expect(reconciled.pinnedChatIds == ["local-chat", "shared-chat", "remote-chat"])
    }

    @Test("dirty profile without baseline rejects pin overflow")
    func rejectsPinOverflowWithoutBaseline() {
        let localPins = (0..<Constants.ChatFavorites.maxPinnedChats).map { "local-\($0)" }
        let reconciled = ProfileMerge.reconcileDirtyProfileWithoutBaseline(
            local: ProfileData(pinnedChatIds: localPins),
            remote: ProfileData(pinnedChatIds: ["remote-chat"])
        )

        #expect(reconciled == nil)
    }

    @Test("adopts populated remote fields when local stayed empty")
    func staleEmptyAdoptsRemote() {
        let baseline = ProfileData(nickname: "", customSystemPrompt: "")
        let local = baseline
        var remote = ProfileData(nickname: "Ada", customSystemPrompt: "Be concise")
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline,
            local: local,
            remote: remote
        )

        #expect(result.merged.nickname == "Ada")
        #expect(result.merged.customSystemPrompt == "Be concise")
        #expect(result.conflicts.isEmpty)
    }

    @Test("combines independent local and remote edits")
    func combinesIndependentEdits() {
        let baseline = ProfileData(nickname: "Ada", profession: "Engineer")
        let local = ProfileData(nickname: "Grace", profession: "Engineer")
        var remote = ProfileData(nickname: "Ada", profession: "Researcher")
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline,
            local: local,
            remote: remote
        )

        #expect(result.merged.nickname == "Grace")
        #expect(result.merged.profession == "Researcher")
        #expect(result.conflicts.isEmpty)
    }

    @Test("preserves an intentional local reset")
    func preservesIntentionalReset() {
        let baseline = ProfileData(customSystemPrompt: "Use headings")
        let local = ProfileData(customSystemPrompt: "")
        var remote = baseline
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline,
            local: local,
            remote: remote
        )

        #expect(result.merged.customSystemPrompt == "")
        #expect(result.conflicts.isEmpty)
    }

    @Test("keeps the local value when the remote omits a field")
    func preservesLocalOnRemoteOmission() {
        let baseline = ProfileData(nickname: "Ada", chatFont: "serif")
        var local = ProfileData(nickname: "Ada", chatFont: "serif")
        local.fieldClocks = ["chatFont": EditClock(v: 3, w: "A")]
        // Remote comes from a client that does not model chatFont.
        var remote = ProfileData(nickname: "Ada")
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline,
            local: trusted(local),
            remote: remote
        )

        #expect(result.merged.chatFont == "serif")
        #expect(result.conflicts.isEmpty)
        #expect(result.merged.fieldClocks?["chatFont"] == EditClock(v: 3, w: "A"))
    }

    @Test("keeps the higher clock when both sides wrote the same value")
    func keepsHigherClockOnEqualValues() {
        let baseline = ProfileData(nickname: "Ada")
        var local = ProfileData(nickname: "Grace")
        local.fieldClocks = ["nickname": EditClock(v: 5, w: "A")]
        var remote = ProfileData(nickname: "Grace")
        remote.fieldClocks = ["nickname": EditClock(v: 9, w: "B")]

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline,
            local: trusted(local),
            remote: trusted(remote)
        )

        #expect(result.merged.nickname == "Grace")
        #expect(result.merged.fieldClocks?["nickname"] == EditClock(v: 9, w: "B"))
        #expect(result.conflicts.isEmpty)
    }

    @Test("retains local value and reports ambiguous conflict")
    func reportsAmbiguousConflict() {
        let baseline = ProfileData(nickname: "Ada")
        let local = ProfileData(nickname: "Grace")
        var remote = ProfileData(nickname: "Lin")
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline,
            local: local,
            remote: remote
        )

        #expect(result.merged.nickname == "Grace")
        #expect(result.conflicts == ["nickname"])
    }

    @Test("merges pinned chat ids as one ordered field")
    func mergesPinnedChatsAtomically() {
        var local = ProfileData(pinnedChatIds: ["local", "shared"])
        local.fieldClocks = ["pinnedChatIds": EditClock(v: 2, w: "A")]
        var remote = ProfileData(pinnedChatIds: ["remote", "shared"])
        remote.fieldClocks = ["pinnedChatIds": EditClock(v: 3, w: "B")]

        let result = ProfileMerge.mergeProfiles(
            local: trusted(local), remote: trusted(remote)
        )

        #expect(result.merged.pinnedChatIds == ["remote", "shared"])
        #expect(result.adoptedRemote)
    }

    @Test("remote omission does not clear pinned chats")
    func preservesPinnedChatsOnRemoteOmission() {
        let baseline = ProfileData(pinnedChatIds: ["chat-a"])
        let local = ProfileData(pinnedChatIds: ["chat-a"])
        var remote = ProfileData(nickname: "Ada")
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline, local: local, remote: remote
        )

        #expect(result.merged.pinnedChatIds == ["chat-a"])
        #expect(result.conflicts.isEmpty)
    }

    @Test("explicit empty pinned chats clears the field")
    func appliesExplicitPinnedChatClear() {
        let baseline = ProfileData(pinnedChatIds: ["chat-a"])
        let local = baseline
        var remote = ProfileData(pinnedChatIds: [])
        remote.version = 2

        let result = ProfileMerge.mergeProfiles(
            baseline: baseline, local: local, remote: remote
        )

        #expect(result.merged.pinnedChatIds == [])
        #expect(result.conflicts.isEmpty)
    }
}

@Suite("Clock-aware conflict resolution")
struct EditClockArbitrationTests {

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
}
