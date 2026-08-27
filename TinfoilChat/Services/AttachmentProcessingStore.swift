import Foundation

struct AttachmentErrorPublicationFence {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    func accepts(_ generation: Int) -> Bool {
        self.generation == generation
    }
}

@MainActor
final class AttachmentProcessingStore {
    struct Publication {
        fileprivate let isCurrentOperation: @MainActor () -> Bool

        @MainActor var isCurrent: Bool { isCurrentOperation() }
    }

    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]

    @discardableResult
    func start(
        id: String,
        operation: @escaping @MainActor (Publication) async -> Void
    ) -> Task<Void, Never> {
        cancel(id: id)
        let token = UUID()
        tokens[id] = token
        let publication = Publication { [weak self] in
            self?.tokens[id] == token
        }
        let task = Task { [weak self] in
            await operation(publication)
            guard self?.tokens[id] == token else { return }
            self?.tokens.removeValue(forKey: id)
            self?.tasks.removeValue(forKey: id)
        }
        tasks[id] = task
        return task
    }

    @discardableResult
    func start(
        id: String,
        stagedFile: ManagedStagedFile,
        operation: @escaping @MainActor (Publication) async -> Void
    ) -> Task<Void, Never> {
        start(id: id) { publication in
            defer { stagedFile.discard() }
            await operation(publication)
        }
    }

    @discardableResult
    func cancel(id: String) -> Task<Void, Never>? {
        tokens.removeValue(forKey: id)
        let task = tasks.removeValue(forKey: id)
        task?.cancel()
        return task
    }

    @discardableResult
    func cancelAll() -> [Task<Void, Never>] {
        tokens.removeAll()
        let canceledTasks = Array(tasks.values)
        tasks.removeAll()
        for task in canceledTasks {
            task.cancel()
        }
        return canceledTasks
    }
}
