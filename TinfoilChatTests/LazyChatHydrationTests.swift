import Foundation
import Testing
@testable import TinfoilChat

private enum LazyHydrationTestError: Error, Sendable {
    case corrupt
}

@MainActor
private final class DeleteAllEventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func recorded() -> [String] {
        events
    }
}

private actor RecordingChatLoadingService: ChatLoadingService {
    private var indexes: [ChatStorageTab: [ChatIndexEntry]] = [:]
    private var storedChats: [ChatStorageTab: [String: Chat]] = [:]
    private var loadCalls: [(String, ChatStorageTab)] = []
    private var saveCalls: [(String, ChatStorageTab)] = []
    private var deleteCalls: [(String, ChatStorageTab)] = []
    private var shouldThrowCorrupt = false
    private var failingSaveIds: Set<String> = []
    private var failingDeleteIds: [ChatStorageTab: Set<String>] = [:]
    private var applyResults: [String: RevisionApplyResult] = [:]
    private var tombstoneOnApplyIds: Set<String> = []

    func setIndex(_ entries: [ChatIndexEntry], storage: ChatStorageTab) {
        indexes[storage] = entries
    }

    func setChat(_ chat: Chat, storage: ChatStorageTab) {
        storedChats[storage, default: [:]][chat.id] = chat
    }

    func setCorruptLoad() {
        shouldThrowCorrupt = true
    }

    func setFailingSaveIds(_ ids: Set<String>) {
        failingSaveIds = ids
    }

    func setFailingDeleteIds(_ ids: Set<String>, storage: ChatStorageTab) {
        failingDeleteIds[storage] = ids
    }

    func setApplyResult(_ result: RevisionApplyResult, chatId: String) {
        applyResults[chatId] = result
    }

    func setTombstoneOnApplyIds(_ ids: Set<String>) {
        tombstoneOnApplyIds = ids
    }

    func loadIndex(userId: String, storage: ChatStorageTab) async throws -> [ChatIndexEntry] {
        indexes[storage] ?? []
    }

    func loadChat(id: String, userId: String, storage: ChatStorageTab) async throws -> Chat {
        loadCalls.append((id, storage))
        if shouldThrowCorrupt { throw LazyHydrationTestError.corrupt }
        guard let chat = storedChats[storage]?[id] else {
            throw ChatLoadingError.chatNotFound(id: id, storage: storage)
        }
        return chat
    }

    func saveChat(_ chat: Chat, userId: String, storage: ChatStorageTab) async throws {
        saveCalls.append((chat.id, storage))
        if failingSaveIds.contains(chat.id) { throw LazyHydrationTestError.corrupt }
        storedChats[storage, default: [:]][chat.id] = chat
    }

    func applyRemoteChatIfFreshResult(
        _ chat: Chat,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool
    ) async throws -> RevisionApplyResult {
        saveCalls.append((chat.id, .cloud))
        if failingSaveIds.contains(chat.id) { throw LazyHydrationTestError.corrupt }
        let existing = indexes[.cloud]?.first { $0.id == chat.id }
        let result = applyResults[chat.id] ?? RevisionApplyPolicy.contentResult(
            existing: existing,
            expectedUpdatedAt: expectedLocalUpdatedAt,
            allowLocallyModified: allowLocallyModified
        )
        if result == .applied {
            storedChats[.cloud, default: [:]][chat.id] = chat
            if let index = indexes[.cloud]?.firstIndex(where: { $0.id == chat.id }) {
                indexes[.cloud]?[index] = ChatIndexEntry(from: chat)
            } else {
                indexes[.cloud, default: []].append(ChatIndexEntry(from: chat))
            }
            if tombstoneOnApplyIds.contains(chat.id) {
                DeletedChatsTracker.shared.markAsDeleted(chat.id)
            }
        }
        return result
    }

    func deleteChat(id: String, userId: String, storage: ChatStorageTab) async throws {
        deleteCalls.append((id, storage))
        if failingDeleteIds[storage]?.contains(id) == true { throw LazyHydrationTestError.corrupt }
        storedChats[storage]?[id] = nil
    }

    func counts() -> (loads: Int, saves: Int, deletes: Int) {
        (loadCalls.count, saveCalls.count, deleteCalls.count)
    }

    func lastLoad() -> (String, ChatStorageTab)? { loadCalls.last }
    func savedChat(id: String, storage: ChatStorageTab) -> Chat? { storedChats[storage]?[id] }
    func deletedStorages() -> [ChatStorageTab] { deleteCalls.map(\.1) }
}

struct LazyChatHydrationTests {
    @Test
    func publishesThousandIndexSummariesWithoutLoadingFullChats() async throws {
        let service = RecordingChatLoadingService()
        let entries = (0..<1_000).map { index in
            ChatIndexEntry(from: makeChat(id: "chat-\(index)", updatedAt: Date(timeIntervalSince1970: Double(index))))
        }
        await service.setIndex(entries, storage: .cloud)

        let loadedIndex = try await service.loadIndex(userId: "user", storage: .cloud)
        let result = ChatSummaryState.page(from: loadedIndex)

        #expect(result.summaries.count == 1_000)
        #expect(result.totalEntries == 1_000)
        #expect(await service.counts().loads == 0)
    }

    @Test
    func hydrationUsesTheRequestedStoreAndSurfacesMissingOrCorruptLoads() async throws {
        let service = RecordingChatLoadingService()
        let cloudChat = makeChat(id: "cloud", updatedAt: Date())
        await service.setChat(cloudChat, storage: .cloud)

        let loaded = try await service.loadChat(id: cloudChat.id, userId: "user", storage: .cloud)
        #expect(loaded.id == cloudChat.id)
        #expect(await service.lastLoad()?.1 == .cloud)

        do {
            _ = try await service.loadChat(id: "missing", userId: "user", storage: .local)
            Issue.record("Expected an explicit missing-chat failure")
        } catch let error as ChatLoadingError {
            #expect(error == .chatNotFound(id: "missing", storage: .local))
        }

        await service.setCorruptLoad()
        await #expect(throws: LazyHydrationTestError.self) {
            _ = try await service.loadChat(id: cloudChat.id, userId: "user", storage: .cloud)
        }
    }

    @Test
    func newerSelectionSuppressesAnOlderHydration() {
        var fence = ChatSelectionFence()
        let generationA = fence.begin(id: "A")
        let generationB = fence.begin(id: "B")

        #expect(!fence.accepts(id: "A", generation: generationA))
        #expect(fence.accepts(id: "B", generation: generationB))
    }

    @Test
    func invalidatingSelectionRejectsHydrationCompletion() {
        var fence = ChatSelectionFence()
        let generation = fence.begin(id: "delete")

        fence.invalidate()

        #expect(!fence.accepts(id: "delete", generation: generation))
        #expect(fence.selectedId == nil)
    }

    @Test
    func projectDeletionDetachesRetainedChatsAndSidebarSummaries() async throws {
        let service = RecordingChatLoadingService()
        var cloudChat = makeChat(id: "cloud-project", updatedAt: Date())
        cloudChat.projectId = "project"
        cloudChat.projectLocallyModified = true
        var localChat = makeChat(id: "local-project", updatedAt: Date())
        localChat.projectId = "project"
        localChat.projectLocallyModified = true
        localChat.isLocalOnly = true
        let rootChat = makeChat(id: "root", updatedAt: Date())
        await service.setIndex(
            [ChatIndexEntry(from: cloudChat), ChatIndexEntry(from: rootChat)],
            storage: .cloud
        )
        await service.setIndex([ChatIndexEntry(from: localChat)], storage: .local)
        await service.setChat(cloudChat, storage: .cloud)
        await service.setChat(rootChat, storage: .cloud)
        await service.setChat(localChat, storage: .local)
        var summaries = [ChatListSummary(from: cloudChat), ChatListSummary(from: rootChat)]

        let detachedSummaryIds = ChatProjectDetachment.detachSummaries(&summaries)
        let cloudResult = try await ChatProjectDetachment.persist(
            userId: "user",
            storage: .cloud,
            loadingService: service
        )
        let localResult = try await ChatProjectDetachment.persist(
            userId: "user",
            storage: .local,
            loadingService: service
        )

        #expect(detachedSummaryIds == Set([cloudChat.id]))
        #expect(summaries.allSatisfy { $0.projectId == nil })
        #expect(cloudResult == .init(failedIds: []))
        #expect(localResult == .init(failedIds: []))
        #expect(await service.savedChat(id: cloudChat.id, storage: .cloud)?.projectId == nil)
        #expect(await service.savedChat(id: localChat.id, storage: .local)?.projectId == nil)
        #expect(await service.savedChat(id: cloudChat.id, storage: .cloud)?.projectLocallyModified == false)
        #expect(await service.savedChat(id: localChat.id, storage: .local)?.projectLocallyModified == false)
        #expect(await service.counts().saves == 2)
    }

    @Test
    func newerTransientSummaryOverridesOlderIndexSummary() {
        let older = makeChat(id: "chat", updatedAt: Date(timeIntervalSince1970: 1))
        var newer = older
        newer.title = "New title"
        newer.updatedAt = Date(timeIntervalSince1970: 2)

        let reconciled = ChatSummaryState.reconcilingIndex(
            [ChatListSummary(from: older)],
            withTransient: [ChatListSummary(from: newer)]
        )

        #expect(reconciled.first?.title == "New title")
    }

    @Test
    func blankUpsertReplacesExistingBlankForStorage() {
        let oldBlank = makeBlankChat(id: "old-blank")
        let newBlank = makeBlankChat(id: "new-blank")
        let regular = makeChat(id: "regular", updatedAt: Date())

        let summaries = ChatSummaryState.upserting(
            ChatListSummary(from: newBlank),
            into: [ChatListSummary(from: oldBlank), ChatListSummary(from: regular)]
        )

        #expect(summaries.filter(\.isBlankChat).map(\.id) == [newBlank.id])
        #expect(summaries.contains { $0.id == regular.id })
    }

    @Test
    func refreshedCloudIndexPreservesLoadedRootIdsAndProjects() {
        var entries = (0..<5).map { index in
            ChatIndexEntry(from: makeChat(
                id: "root-\(index)",
                updatedAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        var projectChat = makeChat(id: "project", updatedAt: Date(timeIntervalSince1970: 10))
        projectChat.projectId = "project-id"
        entries.append(ChatIndexEntry(from: projectChat))

        let result = ChatSummaryState.cloudIndexSummaries(
            from: entries,
            loadedRootIds: ["root-0"],
            firstPageLimit: 2
        )
        let ids = Set(result.summaries.map(\.id))

        #expect(ids == ["root-4", "root-3", "root-0", "project"])
        #expect(result.firstPageIds == ["root-4", "root-3"])
        #expect(result.totalRootEntries == 5)
    }

    @Test
    func paginationPersistenceReturnsOnlySuccessfullySavedChats() async {
        let service = RecordingChatLoadingService()
        let saved = makeChat(id: "saved", updatedAt: Date())
        let failed = makeChat(id: "failed", updatedAt: Date())
        await service.setFailingSaveIds([failed.id])

        let result = await ChatPaginationPersistence.saveCloudChats(
            [saved, failed],
            userId: "user",
            loadingService: service
        )

        #expect(result.summaries.map(\.id) == [saved.id])
        #expect(result.failedIds == [failed.id])
        #expect(await service.savedChat(id: saved.id, storage: .cloud) != nil)
        #expect(await service.savedChat(id: failed.id, storage: .cloud) == nil)
    }

    @Test
    func paginationConflictKeepsLocallyModifiedContentAndSummary() async {
        let service = RecordingChatLoadingService()
        var local = makeChat(id: "conflict", updatedAt: Date(timeIntervalSince1970: 1))
        local.title = "Local edit"
        local.locallyModified = true
        var remote = makeChat(id: local.id, updatedAt: Date(timeIntervalSince1970: 2))
        remote.title = "Remote edit"
        await service.setIndex([ChatIndexEntry(from: local)], storage: .cloud)
        await service.setChat(local, storage: .cloud)

        let result = await ChatPaginationPersistence.saveCloudChats(
            [remote],
            userId: "user",
            loadingService: service
        )

        #expect(result.failedIds.isEmpty)
        #expect(result.summaries.first?.title == local.title)
        #expect(await service.savedChat(id: local.id, storage: .cloud)?.title == local.title)
    }

    @Test
    @MainActor
    func tombstonedPaginationAndSearchRowsNeverApplyOrPublish() async throws {
        let paginationService = RecordingChatLoadingService()
        let paginationChat = makeChat(id: "deleted-pagination", updatedAt: Date())
        DeletedChatsTracker.shared.markAsDeleted(paginationChat.id)
        defer { DeletedChatsTracker.shared.removeFromDeleted(paginationChat.id) }

        let page = await ChatPaginationPersistence.saveCloudChats(
            [paginationChat],
            userId: "user",
            loadingService: paginationService
        )

        #expect(page.outcomes == [.deleted(paginationChat.id)])
        #expect(page.summaries.isEmpty)
        #expect(page.failedIds.isEmpty)
        #expect(page.safelyPersistedCount == 1)
        #expect(await paginationService.counts().saves == 0)

        let searchService = RecordingChatLoadingService()
        let searchChat = makeChat(id: "deleted-search", updatedAt: Date())
        DeletedChatsTracker.shared.markAsDeleted(searchChat.id)
        defer { DeletedChatsTracker.shared.removeFromDeleted(searchChat.id) }
        let searchResult = try await RemoteSearchPersistence.resolve(
            searchChat,
            userId: "user",
            loadingService: searchService
        )

        guard case .deleted = searchResult else {
            Issue.record("Expected tombstoned search result to be skipped")
            return
        }
        #expect(await searchService.counts().saves == 0)
    }

    @Test
    @MainActor
    func tombstoneArrivingDuringPaginationApplyRollsBackStoredChat() async {
        let service = RecordingChatLoadingService()
        let chat = makeChat(id: "delete-race", updatedAt: Date())
        await service.setTombstoneOnApplyIds([chat.id])
        defer { DeletedChatsTracker.shared.removeFromDeleted(chat.id) }

        let result = await ChatPaginationPersistence.saveCloudChats(
            [chat],
            userId: "user",
            loadingService: service
        )

        #expect(result.outcomes == [.deleted(chat.id)])
        #expect(await service.savedChat(id: chat.id, storage: .cloud) == nil)
        #expect(await service.deletedStorages() == [.cloud])
    }

    @Test
    func paginationPartialFailureRetainsOriginalPageState() {
        let original = ChatPaginationPageState(token: "current", hasMore: true)
        let next = ChatPaginationPageState(token: "next", hasMore: false)

        let resolved = ChatPaginationCoordinator.state(
            original: original,
            next: next,
            allRowsPersisted: false
        )

        #expect(resolved == original)
    }

    @Test
    func cancelledPaginationResultRetainsOriginalPageStateWithoutFailure() {
        let result = PaginatedChatsResult(chats: [], cancelled: true)
        let original = ChatPaginationPageState(token: "current", hasMore: true)

        let resolved = ChatPaginationCoordinator.state(
            original: original,
            next: ChatPaginationPageState(token: result.nextToken, hasMore: result.hasMore),
            allRowsPersisted: true,
            pageFailed: result.failed,
            pageCancelled: result.cancelled
        )

        #expect(resolved == original)
        #expect(result.cancelled)
        #expect(!result.failed)
    }

    @Test
    func failedHydrationRetainsRetryIdentityAndStorage() {
        let failedHydration = FailedChatHydration(id: "chat", storage: .local)

        #expect(failedHydration.id == "chat")
        #expect(failedHydration.isLocalOnly)
    }

    @Test
    func anonymousMigrationFailureRemainsPendingUntilLaterSuccess() {
        var hasChatsRemaining = AnonymousChatMigrationPolicy.hasChatsRemaining(allSucceeded: false)
        #expect(hasChatsRemaining)

        hasChatsRemaining = AnonymousChatMigrationPolicy.hasChatsRemaining(allSucceeded: true)
        #expect(!hasChatsRemaining)
    }

    @Test
    func deleteFailureRestoresSelectedConversation() {
        #expect(ChatDeleteSelectionResolution.resolve(
            deletionOwnedSelection: true,
            deletionSucceeded: false,
            deletionGeneration: 2,
            currentGeneration: 2,
            deletedId: "deleted",
            currentSelectedId: "deleted"
        ) == .restore)
        #expect(ChatDeleteSelectionResolution.resolve(
            deletionOwnedSelection: true,
            deletionSucceeded: true,
            deletionGeneration: 2,
            currentGeneration: 2,
            deletedId: "deleted",
            currentSelectedId: "deleted"
        ) == .clearAndReplace)
    }

    @Test
    func newerSelectionIsNotOverriddenByDeleteCompletion() {
        let resolution = ChatDeleteSelectionResolution.resolve(
            deletionOwnedSelection: true,
            deletionSucceeded: true,
            deletionGeneration: 2,
            currentGeneration: 3,
            deletedId: "deleted",
            currentSelectedId: "newer"
        )

        #expect(resolution == .unchanged)
    }

    @Test
    func mutationGateRejectsConcurrentOperationForSameChat() {
        var gate = ChatMutationGate()

        #expect(gate.begin(chatId: "chat"))
        #expect(!gate.begin(chatId: "chat"))
        #expect(gate.begin(chatId: "other"))
        gate.end(chatId: "chat")
        #expect(gate.begin(chatId: "chat"))
    }

    @Test
    func failedEmptyPaginationResultRetainsOriginalPageState() {
        let result = PaginatedChatsResult(chats: [], failed: true)
        let original = ChatPaginationPageState(token: "current", hasMore: true)

        let resolved = ChatPaginationCoordinator.state(
            original: original,
            next: ChatPaginationPageState(token: result.nextToken, hasMore: result.hasMore),
            allRowsPersisted: true,
            pageFailed: result.failed
        )

        #expect(resolved == original)
        #expect(result.failed)
        #expect(!result.cancelled)
    }

    @Test
    @MainActor
    func throwingProjectSaveDoesNotDeleteOriginalStorage() async {
        let service = RecordingChatLoadingService()
        var moved = makeChat(id: "move", updatedAt: Date())
        moved.isLocalOnly = false
        await service.setChat(makeChat(id: moved.id, updatedAt: moved.updatedAt), storage: .local)
        await service.setFailingSaveIds([moved.id])

        await #expect(throws: LazyHydrationTestError.self) {
            try await ChatProjectStorageTransition.persist(
                moved,
                wasLocal: true,
                userId: "user",
                loadingService: service,
                validateAccount: {}
            )
        }

        #expect(await service.savedChat(id: moved.id, storage: .local) != nil)
        #expect(await service.savedChat(id: moved.id, storage: .cloud) == nil)
        #expect(await service.counts().deletes == 0)
    }

    @Test
    @MainActor
    func failedLocalProjectDeleteCompensatesCloudWrite() async {
        let service = RecordingChatLoadingService()
        var original = makeChat(id: "move", updatedAt: Date())
        original.isLocalOnly = true
        var moved = original
        moved.isLocalOnly = false
        moved.projectId = "project"
        await service.setChat(original, storage: .local)
        await service.setFailingDeleteIds([moved.id], storage: .local)

        await #expect(throws: LazyHydrationTestError.self) {
            try await ChatProjectStorageTransition.persist(
                moved,
                wasLocal: true,
                userId: "user",
                loadingService: service,
                validateAccount: {}
            )
        }

        #expect(await service.savedChat(id: moved.id, storage: .local) != nil)
        #expect(await service.savedChat(id: moved.id, storage: .cloud) == nil)
        #expect(await service.deletedStorages() == [.local, .cloud])
    }

    @Test
    @MainActor
    func failedProjectRollbackPreservesBothErrors() async {
        let service = RecordingChatLoadingService()
        var moved = makeChat(id: "rollback", updatedAt: Date())
        moved.isLocalOnly = false
        moved.projectId = "project"
        await service.setFailingDeleteIds([moved.id], storage: .local)
        await service.setFailingDeleteIds([moved.id], storage: .cloud)

        do {
            try await ChatProjectStorageTransition.persist(
                moved,
                wasLocal: true,
                userId: "user",
                loadingService: service,
                validateAccount: {}
            )
            Issue.record("Expected project rollback to fail")
        } catch let error as ChatProjectStorageTransition.RollbackError {
            #expect(!error.primary.localizedDescription.isEmpty)
            #expect(!error.rollback.localizedDescription.isEmpty)
        } catch {
            Issue.record("Expected both project transition errors to be preserved")
        }
    }

    @Test
    func throwingTitleSaveLeavesOriginalValueUncommitted() async {
        let service = RecordingChatLoadingService()
        let original = makeChat(id: "title", updatedAt: Date())
        var proposed = original
        proposed.title = "Updated"
        await service.setChat(original, storage: .cloud)
        await service.setFailingSaveIds([original.id])

        await #expect(throws: LazyHydrationTestError.self) {
            try await service.saveChat(proposed, userId: "user", storage: .cloud)
        }

        #expect(await service.savedChat(id: original.id, storage: .cloud)?.title == original.title)
        #expect(await service.counts().deletes == 0)
    }

    @Test
    func workingSetRetainsCurrentStreamRecoveryAndDirtyChats() {
        let current = makeChat(id: "current", updatedAt: Date())
        var stream = makeChat(id: "stream", updatedAt: Date())
        stream.hasActiveStream = true
        let recovery = makeChat(id: "recovery", updatedAt: Date())
        var dirty = makeChat(id: "dirty", updatedAt: Date())
        dirty.locallyModified = true
        var inactive = makeChat(id: "inactive", updatedAt: Date())
        inactive.locallyModified = false

        let retained = MaterializedChatWorkingSet.retained(
            [current, stream, recovery, dirty, inactive],
            selectedId: current.id,
            streamingIds: [stream.id],
            recoveryIds: [recovery.id],
            operationIds: [dirty.id]
        )

        #expect(Set(retained.map(\.id)) == [current.id, stream.id, recovery.id, dirty.id])
    }

    @Test
    @MainActor
    func deleteAllQuiescesBeforeCloudDeletion() async throws {
        let recorder = DeleteAllEventRecorder()

        try await DeleteAllChatsCoordinator.quiesceAndDeleteCloud(
            closeSaveAdmission: { recorder.append("close") },
            stopProducers: { recorder.append("stop") },
            drainSavesAndBackups: { recorder.append("drain") },
            quiesceUploads: { recorder.append("quiesce") },
            deleteCloud: { recorder.append("delete") },
            recoverFromFailure: { recorder.append("recover") }
        )

        #expect(recorder.recorded() == ["close", "stop", "drain", "quiesce", "delete"])
    }

    @Test
    func recoveryUpdateRejectsStaleOrUnsafeIdentity() {
        #expect(!RecoveryUpdateAdmission.accepts(
            accountIsCurrent: false,
            isAccountTeardownInProgress: false,
            wasSelected: true,
            isStillSelected: true,
            wasMutating: false,
            isMutating: false,
            identityExists: true,
            isStreaming: false
        ))
        #expect(!RecoveryUpdateAdmission.accepts(
            accountIsCurrent: true,
            isAccountTeardownInProgress: false,
            wasSelected: true,
            isStillSelected: true,
            wasMutating: false,
            isMutating: true,
            identityExists: true,
            isStreaming: false
        ))
        #expect(!RecoveryUpdateAdmission.accepts(
            accountIsCurrent: true,
            isAccountTeardownInProgress: false,
            wasSelected: true,
            isStillSelected: true,
            wasMutating: false,
            isMutating: false,
            identityExists: false,
            isStreaming: false
        ))
    }

    @Test
    func authoritativeIndexRemovesCleanSelectionButRetainsDirtyAndStreamingChats() {
        let clean = makeChat(id: "clean", updatedAt: Date())
        var dirty = makeChat(id: "dirty", updatedAt: Date())
        dirty.locallyModified = true
        var streaming = makeChat(id: "streaming", updatedAt: Date())
        streaming.hasActiveStream = true

        let result = AuthoritativeCloudIndexReconciliation.reconcile(
            indexedSummaries: [],
            authoritativeIds: [],
            materializedChats: [clean, dirty, streaming],
            selectedId: clean.id,
            streamingIds: [streaming.id],
            recoveryIds: [],
            operationIds: []
        )

        #expect(result.removedSelectedChat)
        #expect(Set(result.materializedChats.map(\.id)) == [dirty.id, streaming.id])
        #expect(Set(result.summaries.map(\.id)) == [dirty.id, streaming.id])
    }

    @Test
    func tombstoneExcludesDirtyStreamingSelectionAndRequiresReplacement() {
        var tombstoned = makeChat(id: "tombstoned", updatedAt: Date())
        tombstoned.locallyModified = true
        tombstoned.hasActiveStream = true

        let result = AuthoritativeCloudIndexReconciliation.reconcile(
            indexedSummaries: [ChatListSummary(from: tombstoned)],
            authoritativeIds: [tombstoned.id],
            tombstonedIds: [tombstoned.id],
            materializedChats: [tombstoned],
            selectedId: tombstoned.id,
            currentId: tombstoned.id,
            streamingIds: [tombstoned.id],
            recoveryIds: [tombstoned.id],
            operationIds: [tombstoned.id]
        )

        #expect(result.summaries.isEmpty)
        #expect(result.materializedChats.isEmpty)
        #expect(result.removedSelectedChat)
        #expect(result.removedCurrentChat)
    }

    @Test
    func deleteAllRestorationRecoversOperationalStateAfterClearedMemory() {
        let afterCleanupFailure = DeleteAllOperationalRestoration.resolve(
            inMemoryWasCleared: true,
            hasCurrentChat: false
        )
        let afterCloudFailure = DeleteAllOperationalRestoration.resolve(
            inMemoryWasCleared: false,
            hasCurrentChat: true
        )

        #expect(afterCleanupFailure.reloadEncryptionKey)
        #expect(afterCleanupFailure.ensureUsableChat)
        #expect(afterCleanupFailure.restartSignIn)
        #expect(!afterCloudFailure.reloadEncryptionKey)
        #expect(!afterCloudFailure.ensureUsableChat)
        #expect(afterCloudFailure.restartSignIn)
    }

    @Test
    @MainActor
    func remoteSearchPersistsNewChatAndUsesLocalContentOnFreshnessConflict() async throws {
        let service = RecordingChatLoadingService()
        let remote = makeChat(id: "remote-search", updatedAt: Date())

        let persistenceResult = try await RemoteSearchPersistence.resolve(
            remote,
            userId: "user",
            loadingService: service
        )
        guard case .chat(let persisted) = persistenceResult else {
            Issue.record("Expected remote search chat to persist")
            return
        }
        let reopened = try await service.loadChat(
            id: remote.id,
            userId: "user",
            storage: .cloud
        )
        #expect(persisted.id == remote.id)
        #expect(reopened.id == remote.id)

        let conflictService = RecordingChatLoadingService()
        var local = remote
        local.title = "Local authority"
        local.locallyModified = true
        await conflictService.setChat(local, storage: .cloud)
        await conflictService.setApplyResult(.locallyModified, chatId: remote.id)
        let conflictResult = try await RemoteSearchPersistence.resolve(
            remote,
            userId: "user",
            loadingService: conflictService
        )
        guard case .chat(let resolved) = conflictResult else {
            Issue.record("Expected local search conflict to resolve")
            return
        }
        #expect(resolved.title == local.title)
    }

    @Test
    func summaryPagePreservesIndexFilterOrderAndCount() {
        let entries = (0..<80).map { index -> ChatIndexEntry in
            var chat = makeChat(id: "chat-\(index)", updatedAt: Date(timeIntervalSince1970: Double(index)))
            chat.projectId = index.isMultiple(of: 3) ? "project" : nil
            return ChatIndexEntry(from: chat)
        }

        let page = ChatSummaryState.page(
            from: entries,
            filter: \.isCloudDisplayable,
            limit: 20
        )

        #expect(page.totalEntries == entries.filter(\.isCloudDisplayable).count)
        #expect(page.summaries.count == 20)
        #expect(page.summaries.map(\.updatedAt) == page.summaries.map(\.updatedAt).sorted(by: >))
    }

    private func makeChat(id: String, updatedAt: Date) -> Chat {
        var chat = Chat(
            id: id,
            title: id,
            messages: [Message(role: .user, content: id)],
            createdAt: updatedAt,
            modelType: ChatSearchServiceTests.testModel,
            updatedAt: updatedAt
        )
        chat.locallyModified = false
        return chat
    }

    private func makeBlankChat(id: String) -> Chat {
        Chat(
            id: id,
            title: Chat.placeholderTitle,
            messages: [],
            createdAt: Date(),
            modelType: ChatSearchServiceTests.testModel,
            updatedAt: Date()
        )
    }
}
