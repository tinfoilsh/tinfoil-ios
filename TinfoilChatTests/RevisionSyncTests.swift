//
//  RevisionSyncTests.swift
//  TinfoilChatTests
//

import Foundation
import Testing
@testable import TinfoilChat

struct RevisionSyncTests {
    @Test func revisionDTOsUseDecimalStringsAndSnakeCase() throws {
        let summary = try JSONDecoder().decode(
            EnclaveRevisionSummaryResponse.self,
            from: Data(
                #"{"current_revision":"18446744073709551616","oldest_replayable_revision":"42"}"#.utf8
            )
        )
        #expect(summary.currentRevision == "18446744073709551616")
        #expect(summary.oldestReplayableRevision == "42")

        let request = EnclaveRevisionEventsRequest(
            afterRevision: "42",
            throughRevision: "99",
            cursor: "page-2",
            limit: 50
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        #expect(object["after_revision"] as? String == "42")
        #expect(object["through_revision"] as? String == "99")
        #expect(object["cursor"] as? String == "page-2")
    }

    @Test func revisionEventsDecodeKindAndNullableProject() throws {
        let data = Data(
            #"{"events":[{"revision":"7","kind":"upsert","id":"chat","etag":"3","key_id":"key","project_id":null,"updated_at":"2026-08-11T00:00:00.000Z"}],"next_cursor":null}"#.utf8
        )
        let response = try JSONDecoder().decode(EnclaveRevisionEventsResponse.self, from: data)
        let event = try #require(response.events.first)
        #expect(event.kind == .upsert)
        #expect(event.projectId == nil)
        #expect(response.nextCursor == nil)

        let legacyData = Data(
            #"{"events":[{"revision":"8","kind":"upsert","id":"legacy-null","etag":"1","key_id":null,"project_id":null,"updated_at":"2026-08-11T00:00:00.000Z"},{"revision":"9","kind":"upsert","id":"legacy-empty","etag":"1","key_id":"","project_id":null,"updated_at":"2026-08-11T00:00:00.000Z"}]}"#.utf8
        )
        let legacyResponse = try JSONDecoder().decode(
            EnclaveRevisionEventsResponse.self,
            from: legacyData
        )
        #expect(legacyResponse.events.first?.keyId == nil)
        #expect(legacyResponse.events.last?.keyId == "")
        #expect(try RevisionEventPlanner.orderedLatestEvents(
            legacyResponse.events,
            afterRevision: "7",
            throughRevision: "9"
        ).count == 2)
    }

    @Test func revisionEventsRejectLegacyOperationAliases() {
        let data = Data(
            #"{"events":[{"revision":"7","operation":"upsert","id":"chat","etag":"3","key_id":"key","project_id":null,"updated_at":"2026-08-11T00:00:00.000Z"}]}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EnclaveRevisionEventsResponse.self, from: data)
        }
    }

    @Test func snapshotAllowsLegacyRowsWithoutKeyId() throws {
        let data = Data(
            #"{"items":[{"id":"legacy-null","etag":"1","key_id":null,"project_id":null,"updated_at":"2026-08-11T00:00:00.000Z"},{"id":"legacy-empty","etag":"1","key_id":"","project_id":null,"updated_at":"2026-08-11T00:00:00.000Z"}],"snapshot_revision":"9","next_cursor":null}"#.utf8
        )
        let response = try JSONDecoder().decode(
            EnclaveRevisionSnapshotResponse.self,
            from: data
        )
        #expect(response.items.first?.keyId == nil)
        #expect(response.items.last?.keyId == "")
    }

    @Test func decimalRevisionComparisonDoesNotOverflow() {
        #expect(
            DecimalRevision.compare("18446744073709551616", "9999999999999999999")
                == .orderedDescending
        )
        #expect(DecimalRevision.compare("0007", "7") == .orderedSame)
        #expect(DecimalRevision.compare("invalid", "7") == nil)
    }

    @Test func checkpointStorageIsAccountScopedAndRejectsInvalidValues() {
        let suite = "revision-checkpoint-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = RevisionCheckpointStore(defaults: defaults)

        store.save("12", userId: "a")
        store.save("34", userId: "b")
        store.save("bad", userId: "a")

        #expect(store.load(userId: "a") == "12")
        #expect(store.load(userId: "b") == "34")
        store.clear(userId: "a")
        #expect(store.load(userId: "a") == nil)
    }

    @Test func plannerValidatesOrderAndKeepsLatestEventPerChat() throws {
        let events = [
            event(revision: "11", operation: .upsert, id: "a"),
            event(revision: "12", operation: .upsert, id: "b"),
            event(revision: "13", operation: .delete, id: "a"),
        ]
        let planned = try RevisionEventPlanner.orderedLatestEvents(
            events,
            afterRevision: "10",
            throughRevision: "13"
        )
        #expect(planned.map(\.revision) == ["12", "13"])
        #expect(planned.last?.kind == .delete)

        #expect(throws: RevisionSyncError.self) {
            _ = try RevisionEventPlanner.orderedLatestEvents(
                [events[1], events[0]],
                afterRevision: "10",
                throughRevision: "13"
            )
        }
    }

    @Test func plannerClassifiesMalformedEventRevisionSeparatelyFromOrderErrors() {
        do {
            _ = try RevisionEventPlanner.orderedLatestEvents(
                [event(revision: "not-a-revision", operation: .upsert, id: "a")],
                afterRevision: "10",
                throughRevision: "13"
            )
            Issue.record("Expected malformed revision to be rejected")
        } catch RevisionSyncError.invalidRevision {
        } catch {
            Issue.record("Expected invalidRevision, got \(error)")
        }

        do {
            _ = try RevisionEventPlanner.orderedLatestEvents(
                [
                    event(revision: "12", operation: .upsert, id: "a"),
                    event(revision: "11", operation: .upsert, id: "b"),
                ],
                afterRevision: "10",
                throughRevision: "13"
            )
            Issue.record("Expected out-of-order revisions to be rejected")
        } catch RevisionSyncError.outOfOrderEvents {
        } catch {
            Issue.record("Expected outOfOrderEvents, got \(error)")
        }
    }

    @Test func snapshotOnlyHydratesRecentMissingHistory() {
        let remote = (1...5).map { index in
            EnclaveRevisionSnapshotItem(
                id: "chat-\(index)",
                etag: "1",
                keyId: "key",
                projectId: nil,
                updatedAt: "2026-08-0\(index)T00:00:00.000Z"
            )
        }
        let selected = SnapshotReconciliation.contentItems(
            local: [],
            remote: remote,
            recentLimit: 2
        )
        #expect(Set(selected.map(\.id)) == ["chat-4", "chat-5"])
    }

    @Test func contentIntegrityRetainsMissingIndexedIdsForRepair() {
        let availableIds: Set<String> = ["present"]

        let missingIds = ChatContentIntegrity.missingIds(
            indexIds: ["present", "missing", "missing"]
        ) { availableIds.contains($0) }

        #expect(missingIds == ["missing"])
    }

    @Test func contentRepairIgnoresPendingDeletes() {
        let candidates = ChatContentIntegrity.repairCandidates(
            repairIds: ["missing", "pending-delete", "removed"],
            indexedIds: ["missing", "pending-delete"],
            ignoredIds: ["pending-delete"]
        )

        #expect(candidates == ["missing"])
    }

    @Test func contentRepairPrunesOnlyIdsAbsentEverywhere() {
        let unrecoverable = ChatContentIntegrity.unrecoverableIds(
            repairIds: ["orphaned", "pullable", "pending-delete"],
            remoteIds: ["pullable"],
            pendingDeleteIds: ["pending-delete"]
        )

        #expect(unrecoverable == ["orphaned"])
    }

    @MainActor
    @Test func pendingMetadataSelectionExcludesLocalOnlyAndCleanChats() {
        var pendingChat = ChatSearchServiceTests.makeChat(id: "pending", title: "Pending")
        pendingChat.syncedAt = Date()
        pendingChat.locallyModified = true
        var cleanChat = ChatSearchServiceTests.makeChat(id: "clean", title: "Clean")
        cleanChat.syncedAt = Date()
        cleanChat.locallyModified = false
        var localOnlyChat = ChatSearchServiceTests.makeChat(id: "local", title: "Local")
        localOnlyChat.isLocalOnly = true

        #expect(ChatIndexEntry(from: pendingChat).needsCloudUpload)
        #expect(!ChatIndexEntry(from: cleanChat).needsCloudUpload)
        #expect(!ChatIndexEntry(from: localOnlyChat).needsCloudUpload)
        var failedChat = pendingChat
        failedChat.decryptionFailed = true
        #expect(!ChatIndexEntry(from: failedChat).needsCloudUpload)
        var emptyChat = pendingChat
        emptyChat.messages = []
        #expect(!ChatIndexEntry(from: emptyChat).needsCloudUpload)
        #expect(!ChatIndexEntry(from: localOnlyChat).requiresCloudDelete)
        #expect(!DeleteIntentPlanner.shouldStage(
            entry: ChatIndexEntry(from: localOnlyChat),
            mayHaveInFlightUpload: true
        ))
        let neverSyncedEntry = ChatIndexEntry(from: ChatSearchServiceTests.makeChat(
            id: "never-synced",
            title: "Never Synced"
        ))
        #expect(!neverSyncedEntry.requiresCloudDelete)
        #expect(!DeleteIntentPlanner.shouldStage(entry: neverSyncedEntry))
        #expect(DeleteIntentPlanner.shouldStage(entry: ChatIndexEntry(from: cleanChat)))
    }

    @Test func deleteIntentRoundTripsItsIdempotencyKey() throws {
        let intent = PendingChatDelete(
            chatId: "chat",
            idempotencyKey: "0123456789abcdef0123456789abcdef"
        )
        let decoded = try JSONDecoder().decode(
            PendingChatDelete.self,
            from: JSONEncoder().encode(intent)
        )
        #expect(decoded == intent)
        #expect(DeleteIntentPlanner.intent(
            for: intent.chatId,
            existing: [intent],
            newIdempotencyKey: "different-key"
        ) == intent)
        #expect(!DeleteIntentPlanner.shouldStage(entry: nil))
        #expect(DeleteIntentPlanner.shouldStage(
            entry: nil,
            mayHaveInFlightUpload: true
        ))
        #expect(DeleteIntentPlanner.confirmedAbsent(
            [intent],
            remoteIds: []
        ) == [intent])
        #expect(!DeleteIntentPlanner.shouldApplyRemoteUpsert(
            chatId: intent.chatId,
            pendingDeleteIds: [intent.chatId]
        ))
    }

    @MainActor
    @Test func snapshotDeletionPreservesLocalOnlyAndNeverSyncedCreates() {
        var syncedChat = ChatSearchServiceTests.makeChat(id: "synced", title: "Synced")
        syncedChat.syncedAt = Date()
        var newChat = ChatSearchServiceTests.makeChat(id: "new", title: "New")
        newChat.syncedAt = nil
        var versionedChat = ChatSearchServiceTests.makeChat(id: "versioned", title: "Versioned")
        versionedChat.syncedAt = nil
        versionedChat.syncVersion = 2
        var localOnlyChat = ChatSearchServiceTests.makeChat(id: "local", title: "Local")
        localOnlyChat.syncedAt = Date()
        localOnlyChat.isLocalOnly = true

        let removed = SnapshotReconciliation.locallyRemovedIds(
            local: [syncedChat, newChat, versionedChat, localOnlyChat].map {
                ChatIndexEntry(from: $0)
            },
            remoteIds: []
        )
        #expect(removed == ["synced", "versioned"])
    }

    @MainActor
    @Test func dirtyRowsRejectRemoteContentAndMetadataChanges() {
        var dirtyChat = ChatSearchServiceTests.makeChat(id: "dirty", title: "Dirty")
        dirtyChat.syncedAt = Date()
        dirtyChat.locallyModified = true
        dirtyChat.syncVersion = 4
        dirtyChat.projectId = "local-project"
        let entry = ChatIndexEntry(from: dirtyChat)
        let remote = EnclaveRevisionSnapshotItem(
            id: dirtyChat.id,
            etag: "5",
            keyId: "key",
            projectId: "remote-project",
            updatedAt: "2026-08-11T00:00:00.000Z"
        )

        #expect(SnapshotReconciliation.changedRemoteItems(local: [entry], remote: [remote]).isEmpty)
        #expect(!SnapshotReconciliation.shouldApplyRemoteMetadata(
            to: entry,
            etag: remote.etag,
            projectId: remote.projectId
        ))

        dirtyChat.locallyModified = false
        dirtyChat.projectLocallyModified = true
        let projectDirtyEntry = ChatIndexEntry(from: dirtyChat)
        #expect(SnapshotReconciliation.changedRemoteItems(
            local: [projectDirtyEntry],
            remote: [remote]
        ).isEmpty)
        #expect(!SnapshotReconciliation.shouldApplyRemoteMetadata(
            to: projectDirtyEntry,
            etag: remote.etag,
            projectId: remote.projectId
        ))
    }

    @MainActor
    @Test func snapshotHydratesStaleCleanRowsAndOnlyRecentMissingRows() {
        var stale = ChatSearchServiceTests.makeChat(id: "stale", title: "Stale")
        stale.syncedAt = Date()
        stale.syncVersion = 1
        var dirty = ChatSearchServiceTests.makeChat(id: "dirty", title: "Dirty")
        dirty.syncedAt = Date()
        dirty.syncVersion = 1
        dirty.locallyModified = true
        let remote = [
            EnclaveRevisionSnapshotItem(
                id: "stale", etag: "2", keyId: "key", projectId: nil,
                updatedAt: "2026-08-01T00:00:00.000Z"
            ),
            EnclaveRevisionSnapshotItem(
                id: "dirty", etag: "2", keyId: "key", projectId: nil,
                updatedAt: "2026-08-02T00:00:00.000Z"
            ),
            EnclaveRevisionSnapshotItem(
                id: "older-missing", etag: "1", keyId: "key", projectId: nil,
                updatedAt: "2026-08-03T00:00:00.000Z"
            ),
            EnclaveRevisionSnapshotItem(
                id: "recent-missing", etag: "1", keyId: "key", projectId: nil,
                updatedAt: "2026-08-04T00:00:00.000Z"
            ),
        ]

        let selected = SnapshotReconciliation.contentItems(
            local: [stale, dirty].map { ChatIndexEntry(from: $0) },
            remote: remote,
            recentLimit: 1
        )
        #expect(Set(selected.map(\.id)) == ["stale", "recent-missing"])
    }

    @MainActor
    @Test func snapshotRepairsMissingContentEvenWhenIndexMetadataIsClean() {
        var clean = ChatSearchServiceTests.makeChat(id: "missing-file", title: "Missing")
        clean.syncedAt = Date()
        clean.syncVersion = 2
        clean.locallyModified = false
        let remote = EnclaveRevisionSnapshotItem(
            id: clean.id,
            etag: "2",
            keyId: "key",
            projectId: nil,
            updatedAt: "2026-08-11T00:00:00.000Z"
        )

        let selected = SnapshotReconciliation.contentItems(
            local: [ChatIndexEntry(from: clean)],
            remote: [remote],
            recentLimit: 1,
            missingContentIds: [clean.id]
        )

        #expect(selected == [remote])
    }

    @MainActor
    @Test func snapshotRepairsMissingContentBeforeDirtyMetadata() {
        var dirty = ChatSearchServiceTests.makeChat(id: "missing-file", title: "Missing")
        dirty.syncedAt = Date()
        dirty.syncVersion = 2
        dirty.locallyModified = true
        dirty.projectLocallyModified = true
        let entry = ChatIndexEntry(from: dirty)
        let remote = EnclaveRevisionSnapshotItem(
            id: dirty.id,
            etag: "2",
            keyId: "key",
            projectId: nil,
            updatedAt: "2026-08-11T00:00:00.000Z"
        )

        #expect(SnapshotReconciliation.contentItems(
            local: [entry],
            remote: [remote],
            recentLimit: 1,
            missingContentIds: [dirty.id]
        ) == [remote])
        #expect(RevisionApplyPolicy.contentResult(
            existing: entry,
            expectedUpdatedAt: entry.updatedAt,
            allowLocallyModified: true
        ) == .applied)
    }

    @Test func snapshotRepairsRememberedContentAfterIndexEntryIsRemoved() {
        let remote = EnclaveRevisionSnapshotItem(
            id: "missing-file",
            etag: "2",
            keyId: "key",
            projectId: nil,
            updatedAt: "2026-01-01T00:00:00.000Z"
        )

        let selected = SnapshotReconciliation.contentItems(
            local: [],
            remote: [remote],
            recentLimit: 0,
            missingContentIds: [remote.id]
        )

        #expect(selected == [remote])
    }

    @MainActor
    @Test func reconciliationUsesFirstDuplicateIndexEntryDeterministically() {
        var dirty = ChatSearchServiceTests.makeChat(id: "duplicate", title: "Dirty")
        dirty.locallyModified = true
        var stale = dirty
        stale.locallyModified = false
        stale.syncVersion = 1
        let remote = EnclaveRevisionSnapshotItem(
            id: dirty.id,
            etag: "2",
            keyId: "key",
            projectId: nil,
            updatedAt: "2026-08-11T00:00:00.000Z"
        )

        #expect(SnapshotReconciliation.changedRemoteItems(
            local: [ChatIndexEntry(from: dirty), ChatIndexEntry(from: stale)],
            remote: [remote]
        ).isEmpty)
    }

    @MainActor
    @Test func dirtyCASRefusalAllowsUploadLegWhileOtherRefusalsFail() {
        var original = ChatSearchServiceTests.makeChat(id: "race", title: "Original")
        original.locallyModified = false
        let expectedUpdatedAt = original.updatedAt
        original.updatedAt = expectedUpdatedAt.addingTimeInterval(1)
        original.locallyModified = true
        let dirtyEntry = ChatIndexEntry(from: original)

        #expect(RevisionApplyPolicy.contentResult(
            existing: dirtyEntry,
            expectedUpdatedAt: expectedUpdatedAt,
            allowLocallyModified: false
        ) == .locallyModified)
        #expect(RevisionApplyPolicy.contentResult(
            existing: nil,
            expectedUpdatedAt: expectedUpdatedAt,
            allowLocallyModified: false
        ) == .refused)
    }

    @Test func projectMetadataUploadsOnlyForCreatesOrIntentionalMoves() {
        #expect(ProjectMetadataUploadPolicy.shouldInclude(
            syncVersion: 0,
            projectLocallyModified: false
        ))
        #expect(!ProjectMetadataUploadPolicy.shouldInclude(
            syncVersion: 3,
            projectLocallyModified: false
        ))
        #expect(ProjectMetadataUploadPolicy.shouldInclude(
            syncVersion: 3,
            projectLocallyModified: true
        ))
        #expect(ProjectMetadataUploadPolicy.shouldInclude(
            syncVersion: 3,
            projectLocallyModified: false,
            restoreDeleted: true
        ))
        #expect(ProjectMetadataUploadPolicy.flagAfterUpload(
            current: true,
            editedDuringUpload: false
        ) == false)
        #expect(ProjectMetadataUploadPolicy.flagAfterUpload(
            current: true,
            editedDuringUpload: true
        ) == true)
    }

    @MainActor
    @Test func projectMoveIntentPersistsAndOlderChatsDecodeWithoutIt() throws {
        var chat = ChatSearchServiceTests.makeChat(id: "project-move", title: "Move")
        chat.projectId = "project"
        chat.projectLocallyModified = true
        let encoded = try JSONEncoder().encode(chat)
        let decoded = try JSONDecoder().decode(Chat.self, from: encoded)
        #expect(decoded.projectLocallyModified == true)
        #expect(ChatIndexEntry(from: decoded).projectLocallyModified == true)
        let storedData = try JSONEncoder().encode(StoredChat(from: chat))
        let storedObject = try #require(
            JSONSerialization.jsonObject(with: storedData) as? [String: Any]
        )
        #expect(storedObject["projectLocallyModified"] as? Bool == true)

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "projectLocallyModified")
        let legacy = try JSONDecoder().decode(
            Chat.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.projectLocallyModified == nil)
    }

    private func event(
        revision: String,
        operation: EnclaveRevisionOperation,
        id: String
    ) -> EnclaveRevisionEvent {
        EnclaveRevisionEvent(
            revision: revision,
            kind: operation,
            id: id,
            etag: operation == .upsert ? "1" : nil,
            keyId: operation == .upsert ? "key" : nil,
            projectId: nil,
            updatedAt: "2026-08-11T00:00:00.000Z"
        )
    }
}
