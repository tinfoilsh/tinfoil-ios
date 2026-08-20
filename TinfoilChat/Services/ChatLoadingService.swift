import Foundation

enum ChatLoadingError: Error, Equatable, Sendable {
    case chatNotFound(id: String, storage: ChatStorageTab)
}

struct ChatSelectionFence {
    private(set) var generation = 0
    private(set) var selectedId: String?

    mutating func begin(id: String) -> Int {
        generation += 1
        selectedId = id
        return generation
    }

    mutating func invalidate() {
        generation += 1
        selectedId = nil
    }

    func accepts(id: String, generation: Int) -> Bool {
        self.generation == generation && selectedId == id
    }
}

struct ChatMutationGate {
    private(set) var activeChatIds: Set<String> = []

    mutating func begin(chatId: String) -> Bool {
        activeChatIds.insert(chatId).inserted
    }

    mutating func end(chatId: String) {
        activeChatIds.remove(chatId)
    }
}

struct FailedChatHydration: Equatable {
    let id: String
    let storage: ChatStorageTab

    var isLocalOnly: Bool { storage == .local }
}

protocol ChatLoadingService {
    func loadIndex(userId: String, storage: ChatStorageTab) async throws -> [ChatIndexEntry]
    func loadChat(id: String, userId: String, storage: ChatStorageTab) async throws -> Chat
    func saveChat(_ chat: Chat, userId: String, storage: ChatStorageTab) async throws
    func applyRemoteChatIfFreshResult(
        _ chat: Chat,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool
    ) async throws -> RevisionApplyResult
    func deleteChat(id: String, userId: String, storage: ChatStorageTab) async throws
}

struct FileChatLoadingService: ChatLoadingService {
    func loadIndex(userId: String, storage: ChatStorageTab) async throws -> [ChatIndexEntry] {
        try await fileStorage(for: storage).loadIndex(userId: userId)
    }

    func loadChat(id: String, userId: String, storage: ChatStorageTab) async throws -> Chat {
        guard let chat = try await fileStorage(for: storage).loadChat(chatId: id, userId: userId) else {
            throw ChatLoadingError.chatNotFound(id: id, storage: storage)
        }
        return chat
    }

    func saveChat(_ chat: Chat, userId: String, storage: ChatStorageTab) async throws {
        if storage == .cloud,
           await MainActor.run(body: { DeletedChatsTracker.shared.isDeleted(chat.id) }) {
            throw EncryptedFileStorage.SaveError.remotelyDeleted
        }
        try await fileStorage(for: storage).saveChat(chat, userId: userId)
    }

    func applyRemoteChatIfFreshResult(
        _ chat: Chat,
        userId: String,
        expectedLocalUpdatedAt: Date?,
        allowLocallyModified: Bool
    ) async throws -> RevisionApplyResult {
        try await EncryptedFileStorage.cloud.applyRemoteChatIfFreshResult(
            chat,
            userId: userId,
            expectedLocalUpdatedAt: expectedLocalUpdatedAt,
            allowLocallyModified: allowLocallyModified
        )
    }

    func deleteChat(id: String, userId: String, storage: ChatStorageTab) async throws {
        try await fileStorage(for: storage).deleteChat(chatId: id, userId: userId)
    }

    private func fileStorage(for storage: ChatStorageTab) -> EncryptedFileStorage {
        switch storage {
        case .cloud: return .cloud
        case .local: return .local
        }
    }
}

enum ChatPaginationPersistence {
    enum RowOutcome: Equatable {
        case applied(ChatListSummary)
        case retained(ChatListSummary)
        case deleted(String)
        case failed(String)
    }

    struct Result {
        let outcomes: [RowOutcome]

        var summaries: [ChatListSummary] {
            outcomes.compactMap { outcome in
                switch outcome {
                case .applied(let summary), .retained(let summary): summary
                case .deleted, .failed: nil
                }
            }
        }

        var failedIds: [String] {
            outcomes.compactMap { outcome in
                guard case .failed(let id) = outcome else { return nil }
                return id
            }
        }

        var safelyPersistedCount: Int {
            outcomes.count - failedIds.count
        }
    }

    @MainActor
    static func saveCloudChats(
        _ chats: [Chat],
        userId: String,
        loadingService: any ChatLoadingService
    ) async -> Result {
        let localEntries: [ChatIndexEntry]
        do {
            localEntries = try await loadingService.loadIndex(userId: userId, storage: .cloud)
        } catch {
            return Result(outcomes: chats.map {
                DeletedChatsTracker.shared.isDeleted($0.id)
                    ? .deleted($0.id)
                    : .failed($0.id)
            })
        }
        let localById = Dictionary(
            localEntries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var outcomes: [RowOutcome] = []
        for chat in chats {
            guard !Task.isCancelled else { break }
            if DeletedChatsTracker.shared.isDeleted(chat.id) {
                outcomes.append(.deleted(chat.id))
                continue
            }
            do {
                let result = try await loadingService.applyRemoteChatIfFreshResult(
                    chat,
                    userId: userId,
                    expectedLocalUpdatedAt: localById[chat.id]?.updatedAt,
                    allowLocallyModified: false
                )
                guard !Task.isCancelled else { break }
                guard !DeletedChatsTracker.shared.isDeleted(chat.id) else {
                    do {
                        try await loadingService.deleteChat(
                            id: chat.id,
                            userId: userId,
                            storage: .cloud
                        )
                        outcomes.append(.deleted(chat.id))
                    } catch {
                        outcomes.append(.failed(chat.id))
                    }
                    continue
                }
                if result == .applied {
                    outcomes.append(.applied(ChatListSummary(from: chat)))
                } else if let existing = localById[chat.id] {
                    outcomes.append(.retained(ChatListSummary(from: existing)))
                } else {
                    outcomes.append(.failed(chat.id))
                }
            } catch {
                guard !Task.isCancelled else { break }
                outcomes.append(
                    DeletedChatsTracker.shared.isDeleted(chat.id)
                        ? .deleted(chat.id)
                        : .failed(chat.id)
                )
            }
        }
        return Result(outcomes: outcomes)
    }
}

enum RemoteSearchPersistence {
    enum Result {
        case chat(Chat)
        case deleted
    }

    @MainActor
    static func resolve(
        _ remoteChat: Chat,
        userId: String,
        loadingService: any ChatLoadingService,
        validateOperation: @MainActor () throws -> Void = {}
    ) async throws -> Result {
        try validateOperation()
        guard !DeletedChatsTracker.shared.isDeleted(remoteChat.id) else { return .deleted }
        let index = try await loadingService.loadIndex(userId: userId, storage: .cloud)
        try validateOperation()
        guard !DeletedChatsTracker.shared.isDeleted(remoteChat.id) else { return .deleted }
        if index.contains(where: { $0.id == remoteChat.id }) {
            let local = try await loadingService.loadChat(
                id: remoteChat.id,
                userId: userId,
                storage: .cloud
            )
            try validateOperation()
            if DeletedChatsTracker.shared.isDeleted(remoteChat.id) {
                try await loadingService.deleteChat(
                    id: remoteChat.id,
                    userId: userId,
                    storage: .cloud
                )
                return .deleted
            }
            return .chat(local)
        }

        guard !DeletedChatsTracker.shared.isDeleted(remoteChat.id) else { return .deleted }
        let result: RevisionApplyResult
        do {
            result = try await loadingService.applyRemoteChatIfFreshResult(
                remoteChat,
                userId: userId,
                expectedLocalUpdatedAt: nil,
                allowLocallyModified: false
            )
        } catch {
            guard DeletedChatsTracker.shared.isDeleted(remoteChat.id) else { throw error }
            return .deleted
        }
        try validateOperation()
        if DeletedChatsTracker.shared.isDeleted(remoteChat.id) {
            try await loadingService.deleteChat(
                id: remoteChat.id,
                userId: userId,
                storage: .cloud
            )
            return .deleted
        }
        if result == .applied {
            return .chat(remoteChat)
        }
        let local = try await loadingService.loadChat(
            id: remoteChat.id,
            userId: userId,
            storage: .cloud
        )
        try validateOperation()
        if DeletedChatsTracker.shared.isDeleted(remoteChat.id) {
            try await loadingService.deleteChat(
                id: remoteChat.id,
                userId: userId,
                storage: .cloud
            )
            return .deleted
        }
        return .chat(local)
    }
}

enum DeleteAllChatsCoordinator {
    @MainActor
    static func quiesceAndDeleteCloud(
        closeSaveAdmission: () -> Void,
        stopProducers: () async -> Void,
        drainSavesAndBackups: () async -> Void,
        quiesceUploads: () async throws -> Void,
        deleteCloud: () async throws -> Void,
        recoverFromFailure: () async -> Void
    ) async throws {
        closeSaveAdmission()
        await stopProducers()
        await drainSavesAndBackups()
        do {
            try await quiesceUploads()
            try await deleteCloud()
        } catch {
            await recoverFromFailure()
            throw error
        }
    }
}

struct DeleteAllOperationalRestoration: Equatable {
    let reloadEncryptionKey: Bool
    let ensureUsableChat: Bool
    let restartSignIn: Bool

    static func resolve(inMemoryWasCleared: Bool, hasCurrentChat: Bool) -> Self {
        Self(
            reloadEncryptionKey: inMemoryWasCleared,
            ensureUsableChat: inMemoryWasCleared || !hasCurrentChat,
            restartSignIn: true
        )
    }
}

struct RecoveryUpdateAdmission {
    static func accepts(
        accountIsCurrent: Bool,
        isAccountTeardownInProgress: Bool,
        wasSelected: Bool,
        isStillSelected: Bool,
        wasMutating: Bool,
        isMutating: Bool,
        identityExists: Bool,
        isStreaming: Bool
    ) -> Bool {
        accountIsCurrent
            && !isAccountTeardownInProgress
            && (!wasSelected || isStillSelected)
            && !wasMutating
            && !isMutating
            && identityExists
            && !isStreaming
    }
}

struct ChatPaginationPageState: Equatable {
    let token: String?
    let hasMore: Bool
}

enum ChatPaginationCoordinator {
    static func state(
        original: ChatPaginationPageState,
        next: ChatPaginationPageState,
        allRowsPersisted: Bool,
        pageFailed: Bool = false,
        pageCancelled: Bool = false
    ) -> ChatPaginationPageState {
        allRowsPersisted && !pageFailed && !pageCancelled ? next : original
    }
}

enum AnonymousChatMigrationPolicy {
    static func hasChatsRemaining(allSucceeded: Bool) -> Bool {
        !allSucceeded
    }
}

enum ChatDeleteSelectionResolution: Equatable {
    case unchanged
    case restore
    case clearAndReplace

    static func resolve(
        deletionOwnedSelection: Bool,
        deletionSucceeded: Bool,
        deletionGeneration: Int,
        currentGeneration: Int,
        deletedId: String,
        currentSelectedId: String?
    ) -> Self {
        guard deletionOwnedSelection,
              deletionGeneration == currentGeneration,
              currentSelectedId == deletedId || currentSelectedId == nil
        else {
            return .unchanged
        }
        return deletionSucceeded ? .clearAndReplace : .restore
    }
}

enum ChatProjectStorageTransition {
    struct RollbackError: LocalizedError {
        let primary: any Error
        let rollback: any Error

        var errorDescription: String? {
            "\(primary.localizedDescription) Cleanup also failed: \(rollback.localizedDescription)"
        }
    }

    @MainActor
    static func persist(
        _ movedChat: Chat,
        wasLocal: Bool,
        userId: String,
        loadingService: any ChatLoadingService,
        validateAccount: () throws -> Void
    ) async throws {
        try await loadingService.saveChat(movedChat, userId: userId, storage: .cloud)
        do {
            try validateAccount()
        } catch {
            if wasLocal {
                do {
                    try await loadingService.deleteChat(id: movedChat.id, userId: userId, storage: .cloud)
                } catch let rollbackError {
                    throw RollbackError(primary: error, rollback: rollbackError)
                }
            }
            throw error
        }
        guard wasLocal else { return }

        do {
            try await loadingService.deleteChat(id: movedChat.id, userId: userId, storage: .local)
        } catch {
            let localDeleteError = error
            do {
                try await loadingService.deleteChat(id: movedChat.id, userId: userId, storage: .cloud)
            } catch let rollbackError {
                throw RollbackError(primary: localDeleteError, rollback: rollbackError)
            }
            throw localDeleteError
        }
    }
}

enum ChatProjectDetachment {
    struct Result: Equatable {
        let detachedIds: [String]
        let failedIds: [String]
    }

    static func detachSummaries(_ summaries: inout [ChatListSummary]) -> Set<String> {
        var detachedIds: Set<String> = []
        for index in summaries.indices where summaries[index].projectId != nil {
            detachedIds.insert(summaries[index].id)
            summaries[index].projectId = nil
        }
        return detachedIds
    }

    static func detachChats(_ chats: inout [Chat]) {
        for index in chats.indices where chats[index].projectId != nil {
            chats[index].projectId = nil
            chats[index].projectLocallyModified = false
        }
    }

    @MainActor
    static func persist(
        userId: String,
        storage: ChatStorageTab,
        loadingService: any ChatLoadingService
    ) async throws -> Result {
        let entries = try await loadingService.loadIndex(userId: userId, storage: storage)
        var detachedIds: [String] = []
        var failedIds: [String] = []

        for entry in entries where entry.projectId != nil {
            do {
                var chat = try await loadingService.loadChat(
                    id: entry.id,
                    userId: userId,
                    storage: storage
                )
                chat.projectId = nil
                chat.projectLocallyModified = false
                try await loadingService.saveChat(chat, userId: userId, storage: storage)
                detachedIds.append(chat.id)
            } catch {
                failedIds.append(entry.id)
            }
        }

        return Result(detachedIds: detachedIds, failedIds: failedIds)
    }
}

enum ChatSummaryState {
    static func page(
        from entries: [ChatIndexEntry],
        excluding excludedIds: Set<String> = [],
        filter: ((ChatIndexEntry) -> Bool)? = nil,
        limit: Int? = nil
    ) -> (summaries: [ChatListSummary], totalEntries: Int) {
        let sorted = entries
            .filter { !excludedIds.contains($0.id) }
            .filter { filter?($0) ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
        let pageEntries = limit.map { Array(sorted.prefix($0)) } ?? sorted
        return (pageEntries.map(ChatListSummary.init(from:)), sorted.count)
    }

    static func upserting(_ summary: ChatListSummary, into summaries: [ChatListSummary]) -> [ChatListSummary] {
        var result = summary.isBlankChat
            ? summaries.filter { !$0.isBlankChat }
            : summaries
        if let index = result.firstIndex(where: { $0.id == summary.id }) {
            result[index] = summary
        } else {
            result.append(summary)
        }
        return sorted(result)
    }

    static func removing(id: String, from summaries: [ChatListSummary]) -> [ChatListSummary] {
        summaries.filter { $0.id != id }
    }

    static func reconcilingIndex(
        _ indexed: [ChatListSummary],
        withTransient transient: [ChatListSummary]
    ) -> [ChatListSummary] {
        var byId = Dictionary(indexed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for summary in transient {
            if let indexedSummary = byId[summary.id] {
                if summary.isBlankChat
                    || summary.isTemporary
                    || summary.updatedAt >= indexedSummary.updatedAt {
                    byId[summary.id] = summary
                }
            } else {
                byId[summary.id] = summary
            }
        }
        return sorted(Array(byId.values))
    }

    static func cloudIndexSummaries(
        from entries: [ChatIndexEntry],
        loadedRootIds: Set<String>,
        firstPageLimit: Int
    ) -> (summaries: [ChatListSummary], totalRootEntries: Int, firstPageIds: Set<String>) {
        let root = entries
            .filter(\.isCloudDisplayable)
            .sorted { $0.updatedAt > $1.updatedAt }
        let firstPageIds = Set(root.prefix(firstPageLimit).map(\.id))
        let retainedRootIds = firstPageIds.union(loadedRootIds)
        let rootSummaries = root
            .filter { retainedRootIds.contains($0.id) }
            .map(ChatListSummary.init(from:))
        let projectSummaries = entries
            .filter { entry in
                entry.projectId != nil
                    && !entry.isLocalOnly
                    && (entry.messageCount > 0 || entry.decryptionFailed || entry.titleState != .placeholder)
            }
            .map(ChatListSummary.init(from:))
        return (
            reconcilingIndex(rootSummaries, withTransient: projectSummaries),
            root.count,
            firstPageIds
        )
    }

    static func orderedUniqueIds(indexedIds: [String], materializedIds: [String]) -> [String] {
        var seen = Set<String>()
        return (indexedIds + materializedIds).filter { seen.insert($0).inserted }
    }

    private static func sorted(_ summaries: [ChatListSummary]) -> [ChatListSummary] {
        summaries.sorted {
            if $0.isBlankChat != $1.isBlankChat { return $0.isBlankChat }
            return $0.updatedAt > $1.updatedAt
        }
    }
}

enum MaterializedChatWorkingSet {
    static func retained(
        _ chats: [Chat],
        selectedId: String?,
        streamingIds: Set<String>,
        recoveryIds: Set<String>,
        operationIds: Set<String> = []
    ) -> [Chat] {
        chats.filter { chat in
            chat.id == selectedId
                || chat.isBlankChat
                || chat.hasActiveStream
                || streamingIds.contains(chat.id)
                || recoveryIds.contains(chat.id)
                || operationIds.contains(chat.id)
        }
    }
}

enum AuthoritativeCloudIndexReconciliation {
    struct Result {
        let summaries: [ChatListSummary]
        let materializedChats: [Chat]
        let removedSelectedChat: Bool
        let removedCurrentChat: Bool
    }

    static func reconcile(
        indexedSummaries: [ChatListSummary],
        authoritativeIds: Set<String>,
        tombstonedIds: Set<String> = [],
        materializedChats: [Chat],
        selectedId: String?,
        currentId: String? = nil,
        streamingIds: Set<String>,
        recoveryIds: Set<String>,
        operationIds: Set<String>
    ) -> Result {
        let retained = materializedChats.filter { chat in
            !tombstonedIds.contains(chat.id)
                && (authoritativeIds.contains(chat.id)
                || chat.isBlankChat
                || chat.isTemporary
                || chat.locallyModified
                || chat.hasActiveStream
                || streamingIds.contains(chat.id)
                || recoveryIds.contains(chat.id)
                || operationIds.contains(chat.id))
        }
        let transient = retained.map(ChatListSummary.init(from:))
        let indexed = indexedSummaries.filter { !tombstonedIds.contains($0.id) }
        func shouldRemoveIdentity(_ id: String?) -> Bool {
            guard let id, !retained.contains(where: { $0.id == id }) else { return false }
            let materialized = materializedChats.first { $0.id == id }
            let summary = indexedSummaries.first { $0.id == id }
            let isProtectedTransient = materialized?.isBlankChat == true
                || materialized?.isTemporary == true
                || summary?.isBlankChat == true
                || summary?.isTemporary == true
            guard !isProtectedTransient else { return false }
            return tombstonedIds.contains(id) || !authoritativeIds.contains(id)
        }
        return Result(
            summaries: ChatSummaryState.reconcilingIndex(indexed, withTransient: transient),
            materializedChats: retained,
            removedSelectedChat: shouldRemoveIdentity(selectedId),
            removedCurrentChat: shouldRemoveIdentity(currentId)
        )
    }
}
