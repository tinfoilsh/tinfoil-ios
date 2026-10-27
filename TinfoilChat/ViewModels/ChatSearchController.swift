//
//  ChatSearchController.swift
//  TinfoilChat
//
//  Debounced search over the account's stored chats, which the chat
//  service searches from an index it builds as chats change. While the
//  index is still being built, the controller asks again so results fill
//  in without any user action.
//

import Foundation

@MainActor
final class ChatSearchController: ObservableObject {
    /// Ranked hits for the current term.
    @Published private(set) var results: [Chat] = []
    /// True from the first keystroke until the current term's results land.
    @Published private(set) var isSearching = false
    /// True while the chat service builds the index; results may be partial.
    @Published private(set) var isIndexing = false
    /// False when the chat service cannot search, as without cloud sync or
    /// a usable key. Callers should fall back to filtering locally loaded
    /// chats by title.
    @Published private(set) var available = true

    private var searchTask: Task<Void, Never>?

    /// Drop all cached state, including in-flight work. Called when the
    /// authenticated user changes so one account's results can never linger
    /// into another account's session.
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
    func updateTerm(_ term: String, account: HarnessAccount?) -> Task<Void, Never>? {
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
        // The indexing banner describes the previous term's outcome;
        // clear it so a fresh query shows the plain searching state
        // until the chat service answers for this term.
        isIndexing = false
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.Harness.Search.debounceSeconds))
            guard !Task.isCancelled else { return }
            await self?.run(term: trimmed, account: account)
        }
        return searchTask
    }

    private func run(term: String, account: HarnessAccount?) async {
        guard let account, account.cloud, account.keyReady else {
            results = []
            isSearching = false
            isIndexing = false
            available = false
            return
        }
        do {
            let page = try await HarnessSearch.search(account, query: term)
            guard !Task.isCancelled else { return }
            available = true
            isIndexing = page.indexing
            results = page.results.map { ChatViewMapping.chat($0, local: false) }
            isSearching = false
            if page.indexing {
                try? await Task.sleep(for: .seconds(Constants.Harness.Search.reindexPollIntervalSeconds))
                guard !Task.isCancelled else { return }
                await run(term: term, account: account)
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            isSearching = false
            isIndexing = false
            available = false
        }
    }
}
