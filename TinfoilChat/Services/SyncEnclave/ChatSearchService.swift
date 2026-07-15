//
//  ChatSearchService.swift
//  TinfoilChat
//
//  Encrypted chat search over the sync enclave. Mirrors the webapp's
//  `services/cloud/chat-search.ts`.
//
//  The enclave keeps a per-user search index sealed under a key
//  derived from the CEK, so queries need the primary key on every
//  call. Results are chat ids + scores only; `resolveSearchResultChats`
//  maps them back to locally stored chats (falling back to a pull for
//  chats outside the loaded pages).
//
//  When the enclave reports `needs_reindex` (index never built, sealed
//  under a different key, or embedding model changed) this service
//  kicks the background rebuild automatically and exposes the
//  in-flight job as a task so callers can re-query once it settles.
//

import Foundation

/// How a reindex request settled. `partial` is a clean, resumable
/// checkpoint; `skipped` means no kick was sent (no eligible key, or
/// a recent failure put kicks on cooldown); `timeout` means the poll
/// budget ran out while the job was still running server-side.
enum ChatSearchReindexSettle: Equatable {
    case completed
    case partial
    case failed
    case timeout
    case skipped
}

struct ChatSearchOutcome: Equatable {
    let results: [EnclaveSearchQueryResult]
    let totalIndexed: Int
    /// True when the enclave has no complete index for this key yet and
    /// a rebuild has been kicked; results may be partial until it settles.
    let indexing: Bool
    /// False when search cannot run at all: no primary key loaded,
    /// fallback keys are still active, or the enclave has no search
    /// backend (older deploy / unconfigured). The UI should fall back
    /// to local title filtering.
    let available: Bool

    static let unavailable = ChatSearchOutcome(
        results: [],
        totalIndexed: 0,
        indexing: false,
        available: false
    )
}

@MainActor
final class ChatSearchService {

    /// Injection seam for tests; production uses `.live`.
    struct Dependencies {
        var searchQuery: (EnclaveSearchQueryRequest) async throws -> EnclaveSearchQueryResponse
        var searchReindex: (EnclaveSearchReindexRequest) async throws -> EnclaveSearchReindexStatusResponse
        var searchReindexStatus: () async throws -> EnclaveSearchReindexStatusResponse
        var pull: (EnclavePullRequest) async throws -> EnclavePullResponse
        var loadLocalChat: (_ chatId: String, _ userId: String) async -> Chat?
        var decodeRemoteChat: (EnclavePullItem) async -> Chat?
        var primaryKeyB64: () -> String?
        var hasActiveFallbackKeys: () -> Bool
        var pullKeys: () -> [EnclavePullKey]?
        var sleep: (TimeInterval) async throws -> Void
        var now: () -> Date
    }

    static let shared = ChatSearchService()

    private let deps: Dependencies
    private var reindexInFlight: Task<ChatSearchReindexSettle, Never>?
    private var lastReindexFailureAt: Date?

    init(dependencies: Dependencies = .live) {
        self.deps = dependencies
    }

    /// The enclave answers 503 when the search backend is not
    /// configured; an older enclave without the routes answers 404/405.
    /// Both mean "no server-side search here", not a transient failure.
    static func isSearchUnavailableError(_ error: Error) -> Bool {
        guard let enclaveError = error as? SyncEnclaveError,
              let status = enclaveError.status else { return false }
        return status == 503 || status == 404 || status == 405
    }

    // MARK: - Query

    /// Rank synced chats against a query using the caller's primary
    /// CEK. Kicks a background reindex (once per settled job) when the
    /// enclave reports the index is missing or incomplete.
    func searchSyncedChats(
        query: String,
        limit: Int = Constants.SyncEnclave.Search.resultLimit
    ) async throws -> ChatSearchOutcome {
        guard let key = deps.primaryKeyB64(),
              !deps.hasActiveFallbackKeys() else {
            return .unavailable
        }
        let response: EnclaveSearchQueryResponse
        do {
            response = try await deps.searchQuery(
                EnclaveSearchQueryRequest(key: key, query: query, limit: limit)
            )
        } catch let error where Self.isSearchUnavailableError(error) {
            return .unavailable
        }
        if response.needsReindex {
            ensureSearchIndex()
        }
        return ChatSearchOutcome(
            results: response.results,
            totalIndexed: response.totalIndexed,
            indexing: response.needsReindex,
            available: true
        )
    }

    // MARK: - Reindex coordination

    /// Kick (or join) the enclave-side index rebuild; the returned task
    /// resolves with how it settled. Concurrent callers share one poll
    /// loop; the enclave itself dedupes kickoffs for the same key set,
    /// so an extra kick after a settle is harmless. A failed run puts
    /// further kicks on a cooldown: the enclave allows an immediate
    /// re-kick after a failure, and every attempt re-pulls and
    /// re-embeds chats, so retrying on each query would loop a
    /// persistent failure at full rebuild cost. Never throws: failures
    /// are logged and settle as `.failed` so fire-and-forget call
    /// sites cannot leak errors.
    @discardableResult
    func ensureSearchIndex() -> Task<ChatSearchReindexSettle, Never> {
        if let inFlight = reindexInFlight { return inFlight }
        if let failedAt = lastReindexFailureAt,
           deps.now().timeIntervalSince(failedAt)
               < Constants.SyncEnclave.Search.reindexFailureCooldownSeconds {
            return Task { .skipped }
        }
        let task = Task { () -> ChatSearchReindexSettle in
            var result: ChatSearchReindexSettle
            do {
                result = try await self.runReindex()
            } catch {
                print("[ChatSearch] reindex failed: \(error)")
                result = .failed
            }
            self.recordReindexSettle(result)
            return result
        }
        reindexInFlight = task
        return task
    }

    private func recordReindexSettle(_ result: ChatSearchReindexSettle) {
        switch result {
        case .failed:
            lastReindexFailureAt = deps.now()
        case .completed, .partial:
            lastReindexFailureAt = nil
        case .timeout, .skipped:
            break
        }
        reindexInFlight = nil
    }

    private static func isTerminalStatus(_ status: String) -> Bool {
        status != "running"
    }

    /// Kickoff always materializes a job, so its terminal status is the
    /// job's own result. An anomalous "idle" here means no job was
    /// created and must not read as success, or it would clear the
    /// failure cooldown and let callers re-query in a loop.
    private static func terminalSettleResult(
        _ response: EnclaveSearchReindexStatusResponse
    ) -> ChatSearchReindexSettle {
        guard response.failed == 0 else { return .failed }
        switch response.status {
        case "completed":
            return response.partial ? .partial : .completed
        case "failed":
            return .failed
        default:
            return .failed
        }
    }

    private static func kickoffSettleResult(
        _ response: EnclaveSearchReindexStatusResponse
    ) -> ChatSearchReindexSettle {
        terminalSettleResult(response)
    }

    /// In a poll, "idle" means no job record exists. The enclave only
    /// retains a finished job for a few minutes, so a poll that resumes
    /// late (e.g. the app was suspended) can land after the record
    /// expired. Treat that as completed: a re-query self-corrects if
    /// the index is still incomplete, whereas mapping it to failure
    /// would start the cooldown for a job that likely succeeded.
    private static func pollSettleResult(
        _ response: EnclaveSearchReindexStatusResponse
    ) -> ChatSearchReindexSettle {
        if response.status == "idle" { return .completed }
        return terminalSettleResult(response)
    }

    private func runReindex() async throws -> ChatSearchReindexSettle {
        guard let primaryKey = deps.primaryKeyB64(),
              !deps.hasActiveFallbackKeys() else {
            return .skipped
        }
        let kicked = try await deps.searchReindex(
            EnclaveSearchReindexRequest(keys: [EnclavePullKey(key: primaryKey)])
        )
        print("[ChatSearch] reindex kicked job=\(kicked.jobId ?? "nil") status=\(kicked.status)")
        if Self.isTerminalStatus(kicked.status) { return Self.kickoffSettleResult(kicked) }
        let deadline = deps.now()
            .addingTimeInterval(Constants.SyncEnclave.Search.reindexPollBudgetSeconds)
        while deps.now() < deadline {
            try await deps.sleep(Constants.SyncEnclave.Search.reindexPollIntervalSeconds)
            let status = try await deps.searchReindexStatus()
            if Self.isTerminalStatus(status.status) {
                print("[ChatSearch] reindex settled job=\(status.jobId ?? "nil") status=\(status.status) indexed=\(status.indexed) failed=\(status.failed) partial=\(status.partial)")
                return Self.pollSettleResult(status)
            }
        }
        return .timeout
    }

    // MARK: - Result resolution

    /// Resolve search result ids to full chats, preserving the
    /// enclave's ranking. Local storage is the fast path; anything not
    /// on this device yet (results can reach past the loaded sidebar
    /// pages) is pulled and decoded without being written back.
    /// Unresolvable ids (e.g. a chat deleted between indexing and the
    /// query) and undecryptable placeholders are dropped.
    func resolveSearchResultChats(
        _ results: [EnclaveSearchQueryResult],
        userId: String?
    ) async -> [Chat] {
        var byId: [String: Chat] = [:]
        var missing: [String] = []
        for result in results {
            if let userId,
               let local = await deps.loadLocalChat(result.id, userId) {
                byId[result.id] = local
            } else {
                missing.append(result.id)
            }
        }
        if !missing.isEmpty, let keys = deps.pullKeys() {
            do {
                let response = try await deps.pull(
                    EnclavePullRequest(
                        scope: .chat,
                        ids: missing,
                        all: nil,
                        cursor: nil,
                        limit: nil,
                        keys: keys
                    )
                )
                for item in response.items where item.ok {
                    if let chat = await deps.decodeRemoteChat(item) {
                        byId[item.id] = chat
                    }
                }
            } catch {
                print("[ChatSearch] search result pull failed: \(error)")
            }
        }
        return results.compactMap { byId[$0.id] }.filter { !$0.decryptionFailed }
    }
}

/// Decode a successful search-result pull while applying the row
/// metadata that is authoritative outside the encrypted plaintext.
func decodeSearchPulledChat(_ item: EnclavePullItem) -> StoredChat? {
    guard item.ok,
          let etag = item.etag,
          let syncVersion = Int(etag),
          syncVersion > 0,
          let plaintextB64 = item.plaintext,
          let plaintext = Data(base64Encoded: plaintextB64),
          var stored = try? JSONDecoder().decode(StoredChat.self, from: plaintext) else {
        return nil
    }
    stored.syncVersion = syncVersion
    if item.projectIdSet == true {
        stored.projectId = item.projectId
    }
    stored.formatVersion = 2
    return stored
}

// MARK: - Live dependencies

extension ChatSearchService.Dependencies {
    static let live = ChatSearchService.Dependencies(
        searchQuery: { try await SyncEnclaveAPI.searchQuery($0) },
        searchReindex: { try await SyncEnclaveAPI.searchReindex($0) },
        searchReindexStatus: { try await SyncEnclaveAPI.searchReindexStatus() },
        pull: { try await SyncEnclaveAPI.pull($0) },
        loadLocalChat: { chatId, userId in
            (try? await EncryptedFileStorage.cloud.loadChat(chatId: chatId, userId: userId)) ?? nil
        },
        decodeRemoteChat: { item in
            guard let stored = decodeSearchPulledChat(item) else { return nil }
            return await stored.toChat()
        },
        primaryKeyB64: { try? CEKEncoding.requirePrimaryKeyB64() },
        hasActiveFallbackKeys: {
            !EncryptionService.shared.getActiveKeys().alternatives.isEmpty
        },
        pullKeys: { CEKEncoding.pullKeysIfAvailable() },
        sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: { Date() }
    )
}
