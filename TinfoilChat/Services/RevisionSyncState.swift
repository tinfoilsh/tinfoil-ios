//
//  RevisionSyncState.swift
//  TinfoilChat
//

import Foundation

struct PendingChatDelete: Codable, Equatable {
    let chatId: String
    let idempotencyKey: String
}

enum DeleteIntentPlanner {
    static func intent(
        for chatId: String,
        existing: [PendingChatDelete],
        newIdempotencyKey: String
    ) -> PendingChatDelete {
        existing.first(where: { $0.chatId == chatId })
            ?? PendingChatDelete(
                chatId: chatId,
                idempotencyKey: newIdempotencyKey
            )
    }

    static func shouldStage(
        entry: ChatIndexEntry?,
        mayHaveInFlightUpload: Bool = false
    ) -> Bool {
        guard entry?.isLocalOnly != true else { return false }
        return entry?.requiresCloudDelete == true || mayHaveInFlightUpload
    }

    static func confirmedAbsent(
        _ intents: [PendingChatDelete],
        remoteIds: Set<String>
    ) -> [PendingChatDelete] {
        intents.filter { !remoteIds.contains($0.chatId) }
    }

    static func shouldApplyRemoteUpsert(
        chatId: String,
        pendingDeleteIds: Set<String>
    ) -> Bool {
        !pendingDeleteIds.contains(chatId)
    }

    /// True when a failed delete indicates a condition that would fail
    /// every remaining intent identically (network trouble, auth, key
    /// problems, attestation, forced upgrade), so the drain should stop
    /// early instead of failing each row in turn. Row-specific outcomes
    /// (conflicts, not-found, idempotency) keep the drain going so one
    /// poison intent can never starve the rest of the cycle.
    static func isAccountWideFailure(_ action: RecoveryAction) -> Bool {
        switch action {
        case .retry, .refreshCurrentKeyAndRetry, .migrateLegacyAndRetry,
             .triggerRecoveryWizard, .surfaceExistingDataUnderOtherKey,
             .blockAllSync:
            return true
        case .abort(let reason):
            return reason == .authenticationRequired || reason == .forbidden
        case .surfaceConflict, .surfaceNotFound:
            return false
        }
    }
}

enum DecimalRevision {
    private static let asciiZero: UInt8 = 48
    private static let asciiNine: UInt8 = 57

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            $0 >= asciiZero && $0 <= asciiNine
        }
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard isValid(lhs), isValid(rhs) else { return nil }
        let normalizedLHS = normalize(lhs)
        let normalizedRHS = normalize(rhs)
        if normalizedLHS.count != normalizedRHS.count {
            return normalizedLHS.count < normalizedRHS.count ? .orderedAscending : .orderedDescending
        }
        if normalizedLHS == normalizedRHS { return .orderedSame }
        return normalizedLHS < normalizedRHS ? .orderedAscending : .orderedDescending
    }

    private static func normalize(_ value: String) -> String {
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

struct RevisionCheckpointStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(userId: String) -> String? {
        guard let value = defaults.string(
            forKey: Constants.StorageKeys.Sync.revisionCheckpoint(userId: userId)
        ), DecimalRevision.isValid(value) else {
            return nil
        }
        return value
    }

    func save(_ revision: String, userId: String) {
        guard DecimalRevision.isValid(revision) else { return }
        defaults.set(
            revision,
            forKey: Constants.StorageKeys.Sync.revisionCheckpoint(userId: userId)
        )
    }

    func clear(userId: String) {
        defaults.removeObject(
            forKey: Constants.StorageKeys.Sync.revisionCheckpoint(userId: userId)
        )
    }
}

enum RevisionEventPlanner {
    static func orderedLatestEvents(
        _ events: [EnclaveRevisionEvent],
        afterRevision: String,
        throughRevision: String
    ) throws -> [EnclaveRevisionEvent] {
        guard DecimalRevision.isValid(afterRevision), DecimalRevision.isValid(throughRevision) else {
            throw RevisionSyncError.invalidRevision
        }
        var previous = afterRevision
        var latestById: [String: EnclaveRevisionEvent] = [:]
        for event in events {
            guard DecimalRevision.isValid(event.revision) else {
                throw RevisionSyncError.invalidRevision
            }
            guard DecimalRevision.compare(event.revision, previous) == .orderedDescending,
                  DecimalRevision.compare(event.revision, throughRevision) != .orderedDescending else {
                throw RevisionSyncError.outOfOrderEvents
            }
            previous = event.revision
            latestById[event.id] = event
        }
        return latestById.values.sorted {
            DecimalRevision.compare($0.revision, $1.revision) == .orderedAscending
        }
    }
}

enum SnapshotReconciliation {
    static func locallyRemovedIds(
        local: [ChatIndexEntry],
        remoteIds: Set<String>
    ) -> [String] {
        local.compactMap { entry in
            guard !entry.isLocalOnly,
                  (entry.syncedAt != nil || entry.syncVersion > 0),
                  !remoteIds.contains(entry.id) else { return nil }
            return entry.id
        }
    }

    static func changedRemoteItems(
        local: [ChatIndexEntry],
        remote: [EnclaveRevisionSnapshotItem],
        missingContentIds: Set<String> = []
    ) -> [EnclaveRevisionSnapshotItem] {
        var localById: [String: ChatIndexEntry] = [:]
        for entry in local where localById[entry.id] == nil {
            localById[entry.id] = entry
        }
        return remote.filter { item in
            guard let entry = localById[item.id] else { return true }
            if missingContentIds.contains(item.id) { return true }
            guard !entry.locallyModified, entry.projectLocallyModified != true else {
                return false
            }
            return entry.decryptionFailed
                || entry.projectId != item.projectId
                || String(entry.syncVersion) != item.etag
        }
    }

    static func shouldApplyRemoteMetadata(
        to entry: ChatIndexEntry,
        etag: String?,
        projectId: String?
    ) -> Bool {
        !entry.locallyModified && entry.projectLocallyModified != true
            && (entry.projectId != projectId || String(entry.syncVersion) != etag)
    }

    static func contentItems(
        local: [ChatIndexEntry],
        remote: [EnclaveRevisionSnapshotItem],
        recentLimit: Int,
        missingContentIds: Set<String> = []
    ) -> [EnclaveRevisionSnapshotItem] {
        var localById: [String: ChatIndexEntry] = [:]
        for entry in local where localById[entry.id] == nil {
            localById[entry.id] = entry
        }
        let recentMissingIds = Set(remote
            .filter { localById[$0.id] == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(recentLimit)
            .map(\.id))
        return changedRemoteItems(
            local: local,
            remote: remote,
            missingContentIds: missingContentIds
        ).filter { item in
            localById[item.id] != nil
                || recentMissingIds.contains(item.id)
                || missingContentIds.contains(item.id)
        }
    }
}

enum ChatContentIntegrity {
    static func missingIds(
        indexIds: [String],
        contentExists: (String) -> Bool
    ) -> Set<String> {
        Set(indexIds.filter { !contentExists($0) })
    }

    static func repairCandidates(
        repairIds: Set<String>,
        indexedIds: Set<String>,
        ignoredIds: Set<String>
    ) -> Set<String> {
        repairIds.intersection(indexedIds).subtracting(ignoredIds)
    }

    /// Ids whose missing content cannot be repaired from anywhere: the
    /// local file is gone and the remote snapshot has no row to pull
    /// from. Left in place they would keep `needsContentRepair` true and
    /// fail every snapshot reconcile, so the repair prunes their index
    /// entries instead. Pending deletes are excluded — their local
    /// absence is intentional and their intents resolve separately.
    static func unrecoverableIds(
        repairIds: Set<String>,
        remoteIds: Set<String>,
        pendingDeleteIds: Set<String>
    ) -> Set<String> {
        repairIds.subtracting(remoteIds).subtracting(pendingDeleteIds)
    }
}

enum ProjectMetadataUploadPolicy {
    static func shouldInclude(
        syncVersion: Int,
        projectLocallyModified: Bool
    ) -> Bool {
        syncVersion == 0 || projectLocallyModified
    }

    static func flagAfterUpload(
        current: Bool?,
        editedDuringUpload: Bool
    ) -> Bool? {
        editedDuringUpload ? current : false
    }
}

enum RevisionApplyResult: Equatable {
    case applied
    case locallyModified
    case refused
}

enum RevisionApplyPolicy {
    static func contentResult(
        existing: ChatIndexEntry?,
        expectedUpdatedAt: Date?,
        allowLocallyModified: Bool
    ) -> RevisionApplyResult {
        if existing?.locallyModified == true && !allowLocallyModified {
            return .locallyModified
        }
        return existing?.updatedAt == expectedUpdatedAt ? .applied : .refused
    }
}

enum RevisionSyncError: Error {
    case invalidRevision
    case outOfOrderEvents
    case incompletePull
    case snapshotChangedDuringPagination
}
