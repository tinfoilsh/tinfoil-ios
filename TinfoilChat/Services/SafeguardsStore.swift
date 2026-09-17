import Combine
import Foundation

@MainActor
final class SafeguardsStore: ObservableObject {
    typealias FetchFlags = @MainActor (String) async throws -> SafeguardFlagsReport

    @Published private(set) var report: SafeguardFlagsReport?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var usesExamples: Bool
    private(set) var userId: String?
    private let fetchFlags: FetchFlags
    private var flaggedChatIds: Set<String> = []
    private var generation = UUID()
    private var request: Task<Void, Never>?

    init(
        usesExamples: Bool = Constants.Safeguards.useExamples,
        fetchFlags: @escaping FetchFlags = SafeguardsAPI.fetchFlags
    ) {
        self.usesExamples = usesExamples
        self.fetchFlags = fetchFlags
    }

    func setUserId(_ userId: String?) {
        guard self.userId != userId else { return }
        self.userId = userId
        clear()
    }

    func isFlagged(_ chatId: String) -> Bool {
        userId != nil && flaggedChatIds.contains(chatId)
    }

    func refresh() async {
        guard let userId else { return }
        if let request {
            await request.value
            return
        }
        let requestGeneration = generation
        let fetchFlags = fetchFlags
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration {
                    self.isLoading = false
                    self.request = nil
                }
            }
            do {
                try Task.checkCancellation()
                let report: SafeguardFlagsReport
                #if DEBUG
                if self.usesExamples {
                    report = .examples(now: Date())
                } else {
                    report = try await fetchFlags(userId)
                }
                #else
                report = try await fetchFlags(userId)
                #endif
                try Task.checkCancellation()
                guard self.generation == requestGeneration, self.userId == userId else { return }
                self.flaggedChatIds = report.flaggedChatIds
                self.report = report
            } catch {
                guard self.generation == requestGeneration,
                      self.userId == userId,
                      !Task.isCancelled else { return }
                self.errorMessage = Constants.Safeguards.loadError
            }
        }
        request = task
        await task.value
    }

    #if DEBUG
    func setUsesExamples(_ value: Bool) {
        guard usesExamples != value else { return }
        usesExamples = value
        clear()
    }
    #endif

    private func clear() {
        generation = UUID()
        request?.cancel()
        request = nil
        flaggedChatIds = []
        report = nil
        errorMessage = nil
        isLoading = false
    }
}
