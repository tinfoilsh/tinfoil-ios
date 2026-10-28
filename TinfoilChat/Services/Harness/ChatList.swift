import Combine
import Foundation
import OSLog

/// A page of stored chats, as the harness lists them.
private struct CloudPage: Decodable {
    var threads: [ThreadSummary]
    var pinned: [ThreadSummary]?
    /// Empty on the last page.
    var nextCursor: String?

    /// The cursor of the page after, if there is one.
    var next: String? {
        guard let nextCursor, !nextCursor.isEmpty else { return nil }
        return nextCursor
    }
}

/// The listed chats of one scope, kept on this device so the list shows at
/// once on the next launch.
struct ChatListSnapshot: Codable, Equatable {
    var threads: [ThreadSummary]
    var pinned: [ThreadSummary]
}

/// Keeps the last listing of each scope in an encrypted file under the
/// account's directory.
final class ChatListCache: Sendable {
    private let directory: URL?
    private let encryptor: ChatEncryptor

    init(directory: URL?, encryptor: ChatEncryptor = DeviceEncryptionService.shared) {
        self.directory = directory
        self.encryptor = encryptor
    }

    private func file(_ projectId: String?) -> URL? {
        directory?.appendingPathComponent("list-\((projectId ?? "all").replacingOccurrences(of: "/", with: "_")).cache")
    }

    func read(projectId: String?) async -> ChatListSnapshot? {
        guard let url = file(projectId), let sealed = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(EncryptedData.self, from: sealed),
              let data = try? await encryptor.decryptData(envelope) else { return nil }
        return try? JSONDecoder().decode(ChatListSnapshot.self, from: data)
    }

    func write(_ snapshot: ChatListSnapshot, projectId: String?) async {
        guard let url = file(projectId), let data = try? JSONEncoder().encode(snapshot),
              let envelope = try? await encryptor.encryptData(data), let sealed = try? JSONEncoder().encode(envelope) else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func clear() {
        guard let directory, let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "cache" { try? FileManager.default.removeItem(at: url) }
    }
}

/// The chats the sidebar lists: the harness's stored chats with cloud sync,
/// page by page, and the chats this device keeps, read again as they
/// change.
@MainActor
final class ChatList: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")
    /// Chats listed per request; more load with the cursor the last page
    /// ends at.
    static let pageSize = 100

    @Published private(set) var cloudListed: [ThreadSummary] = []
    @Published private(set) var pinnedListed: [ThreadSummary] = []
    @Published private(set) var deviceListed: [ThreadSummary] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var loading = false
    /// A page after those listed is loading, as Load More asked.
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?

    private let account: HarnessAccount
    private let device: LocalThreadStore
    private let cache: ChatListCache
    private var projectId: String?
    private var restored = false
    private var loaded = false
    private var retryCursor: String?
    /// The refreshes in flight; the list loads while there is one.
    private var refreshing = 0
    /// Counts listings of the stored chats apart from the open chat, so that
    /// opening a chat keeps the list and only the latest listing applies.
    private var listing = 0
    private var deviceListing = 0
    /// The copy each shown edit replaced, and the edit that replaced it in
    /// turn, so undoing an edit a later one already replaced hands the later
    /// edit the copy to go back to.
    private var previews: [String: [(before: ThreadSummary, after: ThreadSummary)]] = [:]
    /// Reads the stored chats again as the harness reports a change to them,
    /// such as one another device made.
    private var revisionWatch: AnyCancellable?
    /// The list of one project's stored chats, which the project's page
    /// shows. It loads page by page as this list does, and shows the changes
    /// made through this list as they are made.
    @Published private(set) var project: ChatList?
    private var projectWatch: AnyCancellable?

    let cloud: CloudEdits
    let deviceEdits: DeviceEdits

    init(account: HarnessAccount, device: LocalThreadStore, cache: ChatListCache, projectId: String? = nil) {
        self.account = account
        self.device = device
        self.cache = cache
        self.projectId = projectId
        cloud = CloudEdits()
        deviceEdits = DeviceEdits()
        cloud.list = self
        deviceEdits.list = self
        revisionWatch = account.$chatRevision.dropFirst().removeDuplicates().sink { [weak self] _ in self?.reload() }
    }

    var isCloud: Bool { account.cloud }

    func isOnDevice(_ threadId: String) -> Bool {
        deviceListed.contains { $0.id == threadId }
    }

    /// Lists a project's stored chats beside these, or no project's.
    func listProject(_ projectId: String?) {
        guard projectId != project?.projectId else { return }
        projectWatch = nil
        guard let projectId else {
            project = nil
            return
        }
        let listed = ChatList(account: account, device: device, cache: cache, projectId: projectId)
        project = listed
        projectWatch = listed.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        listed.reload()
    }

    // MARK: - Listing

    /// Shows the scope's last listing while the harness's loads. A scope
    /// restored while the cache was read is the one shown.
    func restore(projectId: String?) async {
        if restored, self.projectId == projectId { return }
        listing += 1
        let version = listing
        self.projectId = projectId
        restored = true
        loaded = false
        error = nil
        let cached = await cache.read(projectId: projectId)
        guard version == listing else { return }
        cloudListed = cached?.threads ?? []
        pinnedListed = cached?.pinned ?? []
        nextCursor = nil
    }

    /// Reads the stored chats again: the first pages, or the page after a
    /// cursor. A failure shows in the list, which offers a retry.
    func refresh(after cursor: String? = nil) async throws {
        guard account.cloud else { return }
        await restore(projectId: projectId)
        guard account.keyReady else { return }
        // The project's list is read again with this one when it has not
        // been read since it was cleared, or failed to be.
        if cursor == nil, let project, project.refreshing == 0, !project.loaded || project.error != nil { project.reload() }
        if cursor == nil { listing += 1 }
        let version = listing
        if error != nil { error = nil; loaded = false }
        refreshing += 1
        loading = true
        defer {
            refreshing -= 1
            if refreshing == 0 { loading = false }
        }
        do {
            let wanted = cursor == nil ? max(Self.pageSize, cloudListed.count) : Self.pageSize
            var threads: [ThreadSummary] = []
            var pinned: [ThreadSummary]?
            var next = cursor
            repeat {
                let page: CloudPage = try await account.post(.list, ListRequest(cursor: next, limit: Self.pageSize, projectId: projectId))
                if let listed = page.pinned { pinned = listed }
                threads.append(contentsOf: page.threads.filter { thread in !threads.contains { $0.id == thread.id } })
                if page.next == next { break }
                next = page.next
            } while cursor == nil && next != nil && threads.count < wanted && version == listing
            guard version == listing else { return }
            if cursor != nil {
                cloudListed.append(contentsOf: threads.filter { thread in !cloudListed.contains { $0.id == thread.id } })
            } else {
                cloudListed = threads
                pinnedListed = pinned ?? []
            }
            nextCursor = next
            loaded = true
            error = nil
            retryCursor = nil
            await persist()
        } catch {
            guard version == listing, !account.disposed, !(error is CancellationError) else { return }
            loaded = true
            retryCursor = cursor
            self.error = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func reload(after cursor: String? = nil) -> Task<Void, Never> {
        Task {
            do { try await refresh(after: cursor) } catch {
                Self.logger.error("Failed to list chats: \(error, privacy: .public)")
            }
        }
    }

    /// Reads again what failed to: the page after the cursor it was read
    /// from, or the first pages.
    @discardableResult
    func retry() -> Task<Void, Never> {
        reload(after: retryCursor)
    }

    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard let nextCursor, !loadingMore else { return nil }
        loadingMore = true
        let load = reload(after: nextCursor)
        return Task {
            await load.value
            loadingMore = false
        }
    }

    /// Reads the chats this device keeps again, as they change.
    func reloadDevice() {
        deviceListing += 1
        let request = deviceListing
        Task {
            do {
                let listed = try await device.list()
                if request == deviceListing { deviceListed = listed }
            } catch {
                Self.logger.error("Failed to list local chats: \(error, privacy: .public)")
            }
        }
    }

    /// The stored chats are not listed, as once cloud sync is off.
    func clearCloud(confirmedEmpty: Bool = false) {
        listing += 1
        restored = false
        loaded = confirmedEmpty
        loading = false
        error = nil
        cache.clear()
        cloudListed = []
        pinnedListed = []
        nextCursor = nil
        project?.clearCloud(confirmedEmpty: confirmedEmpty)
    }

    private func persist() async {
        guard account.cloud, !account.disposed, restored else { return }
        await cache.write(ChatListSnapshot(threads: cloudListed, pinned: pinnedListed), projectId: projectId)
    }

    private func inScope(_ summary: ThreadSummary) -> Bool {
        projectId == nil || projectId == summary.projectId
    }

    private func touched() {
        listing += 1
        Task { await persist() }
        if !loaded { reload() }
    }

    // MARK: - Previews

    /// Shows a new title or favorite state of a chat before its store saves
    /// it, and returns what takes it back when the store refuses. Only a
    /// stored chat is a favorite.
    func preview(_ threadId: String, _ patch: ThreadPatch) -> () -> Void {
        guard patch.title != nil || patch.pinned != nil else { return {} }
        func changed(_ summary: ThreadSummary, titleOnly: Bool = false) -> ThreadSummary {
            var next = summary
            if let title = patch.title { next.title = title; next.titleState = .manual }
            if !titleOnly, let pinned = patch.pinned { next.pinned = pinned }
            return next
        }
        var undo: [() -> Void] = []
        if let stored = cloudListed.first(where: { $0.id == threadId }) {
            undo.append(replaceShown(\.cloudListed, stored, changed(stored)))
        }
        if patch.title != nil, let onDevice = deviceListed.first(where: { $0.id == threadId }) {
            undo.append(replaceShown(\.deviceListed, onDevice, changed(onDevice, titleOnly: true)))
        }
        let favorite = pinnedListed.first { $0.id == threadId }
        if let favorite, patch.pinned == false {
            undo.append(removeShown(\.pinnedListed, favorite))
        } else if let favorite {
            undo.append(replaceShown(\.pinnedListed, favorite, changed(favorite)))
        } else if let stored = cloudListed.first(where: { $0.id == threadId }), patch.pinned == true {
            undo.append(appendShown(\.pinnedListed, changed(stored)))
        }
        if let project { undo.append(project.preview(threadId, patch)) }
        return { [weak self] in
            undo.forEach { $0() }
            Task { await self?.persist() }
        }
    }

    /// Leaves a chat out of the list before its store deletes it, and
    /// returns what lists it again when the store refuses.
    func previewRemoval(_ threadId: String) -> () -> Void {
        var undo: [() -> Void] = []
        for path in [\ChatList.cloudListed, \ChatList.pinnedListed, \ChatList.deviceListed] {
            if let before = self[keyPath: path].first(where: { $0.id == threadId }) { undo.append(removeShown(path, before)) }
        }
        if let project { undo.append(project.previewRemoval(threadId)) }
        return { [weak self] in
            undo.forEach { $0() }
            Task { await self?.persist() }
        }
    }

    private func replaceShown(_ path: ReferenceWritableKeyPath<ChatList, [ThreadSummary]>, _ before: ThreadSummary, _ after: ThreadSummary) -> () -> Void {
        previews[before.id, default: []].append((before, after))
        self[keyPath: path] = self[keyPath: path].map { $0 == before ? after : $0 }
        return { [weak self] in
            guard let self else { return }
            var chain = previews[before.id] ?? []
            guard let index = chain.firstIndex(where: { $0.after == after }) else { return }
            let previous = chain[index].before
            chain.remove(at: index)
            if let later = chain.firstIndex(where: { $0.before == after }) { chain[later].before = previous }
            previews[before.id] = chain.isEmpty ? nil : chain
            self[keyPath: path] = self[keyPath: path].map { $0 == after ? previous : $0 }
        }
    }

    /// A store accepted a chat's change: the previews shown for it are
    /// settled, and not taken back by a later refusal.
    private func settlePreviews(_ threadId: String) {
        previews[threadId] = nil
    }

    private func removeShown(_ path: ReferenceWritableKeyPath<ChatList, [ThreadSummary]>, _ before: ThreadSummary) -> () -> Void {
        let index = self[keyPath: path].firstIndex(of: before) ?? 0
        self[keyPath: path].removeAll { $0 == before }
        return { [weak self] in
            guard let self, !self[keyPath: path].contains(where: { $0.id == before.id }) else { return }
            self[keyPath: path].insert(before, at: min(index, self[keyPath: path].count))
        }
    }

    private func appendShown(_ path: ReferenceWritableKeyPath<ChatList, [ThreadSummary]>, _ after: ThreadSummary) -> () -> Void {
        self[keyPath: path].append(after)
        return { [weak self] in self?[keyPath: path].removeAll { $0.id == after.id } }
    }

    // MARK: - Edits

    /// The changes a store makes to the stored chats it lists, which the
    /// project's list shows too.
    @MainActor
    final class CloudEdits: ListEdits {
        weak var list: ChatList?

        func add(_ summary: ThreadSummary) {
            guard let list else { return }
            if list.inScope(summary) { list.cloudListed = [summary] + list.cloudListed.filter { $0.id != summary.id } }
            if summary.pinned { list.pin(summary) }
            list.touched()
            list.project?.cloud.add(summary)
        }

        /// A chat moved into the project a list is of joins it.
        func replace(_ summary: ThreadSummary) {
            guard let list else { return }
            list.settlePreviews(summary.id)
            if list.inScope(summary) {
                if list.projectId != nil, !list.cloudListed.contains(where: { $0.id == summary.id }) {
                    list.cloudListed = [summary] + list.cloudListed
                } else {
                    list.cloudListed = list.cloudListed.map { $0.id == summary.id ? summary : $0 }
                }
            } else {
                list.cloudListed.removeAll { $0.id == summary.id }
            }
            if summary.pinned { list.pin(summary) } else { list.pinnedListed.removeAll { $0.id == summary.id } }
            list.touched()
            list.project?.cloud.replace(summary)
        }

        func remove(_ threadId: String) {
            guard let list else { return }
            list.cloudListed.removeAll { $0.id == threadId }
            list.pinnedListed.removeAll { $0.id == threadId }
            list.touched()
            list.project?.cloud.remove(threadId)
        }

        /// A stored chat as the open chat's run reports it, which is newer
        /// than the listed copy: a new chat joins the list, and a chat whose
        /// reply goes on stays marked running until the list is read again.
        /// The listed favorites still decide whether it is one.
        func reported(_ summary: ThreadSummary) {
            guard let list else { return }
            var shown = summary
            shown.pinned = list.pinnedListed.contains { $0.id == summary.id }
            if list.inScope(shown) { list.cloudListed = [shown] + list.cloudListed.filter { $0.id != shown.id } }
            if shown.pinned { list.pinnedListed = list.pinnedListed.map { $0.id == shown.id ? shown : $0 } }
            list.touched()
            list.project?.cloud.reported(summary)
        }
    }

    /// The changes a store makes to the chats this device lists.
    @MainActor
    final class DeviceEdits: ListEdits {
        weak var list: ChatList?

        func add(_ summary: ThreadSummary) {
            list?.deviceListed = [summary] + (list?.deviceListed.filter { $0.id != summary.id } ?? [])
        }

        func replace(_ summary: ThreadSummary) {
            guard let list else { return }
            list.settlePreviews(summary.id)
            list.deviceListed = list.deviceListed.map { $0.id == summary.id ? summary : $0 }
        }

        func remove(_ threadId: String) {
            list?.deviceListed.removeAll { $0.id == threadId }
        }
    }

    /// The favorites in the order they were pinned, as the harness lists
    /// them: a new one is the last, and one already listed keeps its place.
    private func pin(_ summary: ThreadSummary) {
        if pinnedListed.contains(where: { $0.id == summary.id }) {
            pinnedListed = pinnedListed.map { $0.id == summary.id ? summary : $0 }
        } else {
            pinnedListed.append(summary)
        }
    }
}
