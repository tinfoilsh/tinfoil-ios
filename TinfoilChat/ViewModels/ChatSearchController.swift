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

/// What a failed search tells the user, from its error's code and then its
/// action, and whether searching again may help.
struct SearchFailure: Equatable {
    let message: String
    let canRetry: Bool

    init(_ error: Error) {
        guard let error = error as? HarnessError else {
            self.init("Couldn't reach the chat service. Check your connection and try again.", canRetry: true)
            return
        }
        switch error.code {
        case HarnessErrorCode.searchIndexFailed:
            self.init("Your chats couldn't be prepared for search. Try again.", canRetry: true)
        case HarnessErrorCode.connection:
            self.init("Couldn't reach the chat service. Check your connection and try again.", canRetry: true)
        case HarnessErrorCode.attestation:
            self.init("Couldn't verify the chat service, so your search wasn't sent. Try again.", canRetry: true)
        case HarnessErrorCode.keyMismatch:
            self.init("Your encryption key is out of date. Recover your current key to search your chats.", canRetry: false)
        default:
            switch error.action {
            case .retry, .reload: self.init("The search didn't finish. Try again.", canRetry: true)
            case .wait: self.init("Too many requests right now. Wait a moment, then try again.", canRetry: true)
            case .reauthenticate: self.init("Sign in again to search your chats.", canRetry: false)
            case .unlock: self.init("Unlock your encryption key to search your chats.", canRetry: false)
            case .revise: self.init("Change your search, then try again.", canRetry: false)
            default: self.init("This search couldn't be completed.", canRetry: false)
            }
        }
    }

    private init(_ message: String, canRetry: Bool) {
        self.message = message
        self.canRetry = canRetry
    }
}

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
    /// Why the current term's search failed.
    @Published private(set) var failure: SearchFailure?
    /// Matching chats the chat service could not open.
    @Published private(set) var unreadable = 0

    private var searchTask: Task<Void, Never>?
    private var term = ""

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
        failure = nil
        unreadable = 0
        term = ""
    }

    /// Searches the current term again after a failure.
    func retry(account: HarnessAccount?) {
        updateTerm(term, account: account)
    }

    /// Debounce and run one search per term change. Cancelling the
    /// previous task ensures completions from a superseded term never
    /// set state or schedule a refresh.
    @discardableResult
    func updateTerm(_ term: String, account: HarnessAccount?) -> Task<Void, Never>? {
        searchTask?.cancel()
        searchTask = nil
        self.term = term
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        failure = nil
        unreadable = 0
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
            unreadable = page.unreadable
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
            failure = SearchFailure(error)
        }
    }
}
