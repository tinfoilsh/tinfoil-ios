//
//  ChatSearchController.swift
//  TinfoilChat
//
//  Debounced encrypted search over synced chats, mirroring the
//  webapp's `useChatSearch` hook. When the enclave reports it is
//  rebuilding the index, the controller waits for the job to settle
//  and re-runs the current term so results fill in without any user
//  action.
//

import Foundation

@MainActor
final class ChatSearchController: ObservableObject {
    /// Ranked, fully resolved hits for the current term.
    @Published private(set) var results: [Chat] = []
    /// True from the first keystroke until the current term's results land.
    @Published private(set) var isSearching = false
    /// True while the enclave rebuilds the index; results may be partial.
    @Published private(set) var isIndexing = false
    /// False when server-side search cannot run (no eligible key,
    /// enclave without a search backend). Callers should fall back to
    /// filtering locally loaded chats by title.
    @Published private(set) var available = true

    private let service: ChatSearchService
    private var searchTask: Task<Void, Never>?

    init(service: ChatSearchService = .shared) {
        self.service = service
    }

    /// Drop all cached state, including in-flight work. Called when the
    /// authenticated user changes so one account's decrypted results
    /// can never linger into another account's session.
    func reset() {
        searchTask?.cancel()
        searchTask = nil
        results = []
        isSearching = false
        isIndexing = false
        available = true
    }

    /// Debounce and run one search per term change. Cancelling the
    /// previous task ensures completions from a superseded term never
    /// set state or schedule a refresh.
    @discardableResult
    func updateTerm(_ term: String, userId: String?) -> Task<Void, Never>? {
        searchTask?.cancel()
        searchTask = nil
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            isIndexing = false
            return nil
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Constants.SyncEnclave.Search.debounceSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await self?.run(term: trimmed, userId: userId)
        }
        return searchTask
    }

    private func run(term: String, userId: String?) async {
        do {
            let outcome = try await service.searchSyncedChats(query: term)
            guard !Task.isCancelled else { return }
            available = outcome.available
            isIndexing = outcome.indexing
            let chats = await service.resolveSearchResultChats(outcome.results, userId: userId)
            guard !Task.isCancelled else { return }
            results = chats
            isSearching = false
            if outcome.indexing {
                // Re-query after a full rebuild or a clean partial
                // checkpoint. The latter reports needs_reindex again
                // and resumes from the enclave's checkpoint. Failed,
                // timed-out, and skipped rebuilds stop here.
                let settled = await service.ensureSearchIndex().value
                guard !Task.isCancelled else { return }
                if settled == .completed || settled == .partial {
                    await run(term: term, userId: userId)
                } else {
                    isIndexing = false
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            print("[ChatSearch] search failed: \(error)")
            results = []
            isSearching = false
            isIndexing = false
        }
    }
}
