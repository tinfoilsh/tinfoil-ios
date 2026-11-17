//
//  ArtifactListController.swift
//  TinfoilChat
//
//  The artifacts the replies in the account's stored chats drew, or those
//  of one project's chats, which the chat service lists a page at a time.
//

import Foundation
import Combine

/// What names an artifact among the account's. A model may name calls in
/// different replies alike, so the reply names it with its chat and call.
struct ArtifactKey: Hashable, Sendable {
    let threadId: String
    let messageId: String
    let toolCallId: String
}

extension ListedArtifact {
    var key: ArtifactKey {
        ArtifactKey(threadId: threadId, messageId: messageId, toolCallId: toolCallId)
    }

    /// The kind of source the artifact shows, or nil for a kind this client
    /// does not know, which it shows as a generic artifact.
    var kind: ArtifactPreviewWidget.SourceKind? {
        sourceType.value1.flatMap { ArtifactPreviewWidget.SourceKind(rawValue: $0.rawValue) }
    }
}

@MainActor
final class ArtifactListController: ObservableObject {
    typealias PageLoader = @MainActor (_ cursor: String?) async throws -> ArtifactPage

    /// The artifacts listed so far, each once.
    @Published private(set) var artifacts: [ListedArtifact] = []
    /// True while the first page loads.
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    /// Whether the chat service has artifacts after those listed.
    @Published private(set) var hasMore = false
    /// Why the list, or its next page, could not be read.
    @Published private(set) var error: String?

    private var loader: PageLoader?
    private var nextCursor: String?
    private var listed: Set<ArtifactKey> = []
    private var loadTask: Task<Void, Never>?

    /// Lists the artifacts of the account's stored chats, or of a
    /// project's, from the first page.
    @discardableResult
    func load(account: HarnessAccount?, projectId: String? = nil) -> Task<Void, Never> {
        load { cursor in
            guard let account else { throw CancellationError() }
            return try await HarnessArtifacts.list(account, projectId: projectId, cursor: cursor)
        }
    }

    /// Lists from the first page what a loader reads, in place of what was
    /// listed.
    @discardableResult
    func load(_ loader: @escaping PageLoader) -> Task<Void, Never> {
        reset()
        self.loader = loader
        isLoading = true
        return read(from: nil, loader)
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        loader = nil
        artifacts = []
        listed = []
        nextCursor = nil
        hasMore = false
        error = nil
        isLoadingMore = false
        isLoading = false
    }

    /// Lists the page after the last one listed, when there is one and
    /// nothing is loading.
    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard let loader, let nextCursor, !isLoading, !isLoadingMore else { return nil }
        error = nil
        isLoadingMore = true
        return read(from: nextCursor, loader)
    }

    /// Reads again what could not be read: the next page when some are
    /// listed, and the first otherwise.
    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard let loader else { return nil }
        return nextCursor == nil ? load(loader) : loadMore()
    }

    /// Reads pages from a cursor until one adds an artifact or none is
    /// left. A page may add none: the chats it read drew none, or it lists
    /// again a chat the list was filed again in between pages.
    private func read(from cursor: String?, _ loader: @escaping PageLoader) -> Task<Void, Never> {
        let task = Task { [weak self] in
            var cursor = cursor
            do {
                while true {
                    let page = try await loader(cursor)
                    guard !Task.isCancelled, let self else { return }
                    let added = self.append(page.artifacts)
                    // A cursor that does not advance would list the same
                    // page without end.
                    let next = page.nextCursor.isEmpty || page.nextCursor == cursor ? nil : page.nextCursor
                    self.nextCursor = next
                    self.hasMore = next != nil
                    if added || next == nil { break }
                    cursor = next
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            guard !Task.isCancelled, let self else { return }
            self.isLoading = false
            self.isLoadingMore = false
        }
        loadTask = task
        return task
    }

    /// Adds the artifacts of a page that are not listed yet, and says
    /// whether it added any.
    private func append(_ page: [ListedArtifact]) -> Bool {
        let new = page.filter { listed.insert($0.key).inserted }
        artifacts.append(contentsOf: new)
        return !new.isEmpty
    }
}
