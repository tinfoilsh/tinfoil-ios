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
        try await fileStorage(for: storage).saveChat(chat, userId: userId)
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
    @MainActor
    static func saveCloudChats(
        _ chats: [Chat],
        userId: String,
        loadingService: any ChatLoadingService
    ) async -> (saved: [Chat], failedIds: [String]) {
        var saved: [Chat] = []
        var failedIds: [String] = []
        for chat in chats {
            guard !Task.isCancelled else { break }
            do {
                try await loadingService.saveChat(chat, userId: userId, storage: .cloud)
                guard !Task.isCancelled else { break }
                saved.append(chat)
            } catch {
                guard !Task.isCancelled else { break }
                failedIds.append(chat.id)
            }
        }
        return (saved, failedIds)
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
                try? await loadingService.deleteChat(id: movedChat.id, userId: userId, storage: .cloud)
            }
            throw error
        }
        guard wasLocal else { return }

        do {
            try await loadingService.deleteChat(id: movedChat.id, userId: userId, storage: .local)
        } catch {
            let localDeleteError = error
            try await loadingService.deleteChat(id: movedChat.id, userId: userId, storage: .cloud)
            throw localDeleteError
        }
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
