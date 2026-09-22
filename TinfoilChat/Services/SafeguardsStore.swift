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
    private var sessionId: String?
    private let fetchFlags: FetchFlags
    @Published private(set) var flaggedChatIds: Set<String> = []
    #if DEBUG
    @Published private(set) var simulatedFlaggedChatIds: Set<String> = []
    #endif
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

    func setSessionId(_ sessionId: String?) {
        guard self.sessionId != sessionId else { return }
        self.sessionId = sessionId
        clear()
    }

    func isFlagged(_ chatId: String) -> Bool {
        guard userId != nil else { return false }
        #if DEBUG
        if simulatedFlaggedChatIds.contains(chatId) { return true }
        #endif
        return flaggedChatIds.contains(chatId)
    }

    func isSimulatedFlag(_ chatId: String) -> Bool {
        #if DEBUG
        simulatedFlaggedChatIds.contains(chatId)
        #else
        false
        #endif
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
        clearReport()
    }

    func toggleSimulatedFlag(_ chatId: String) {
        guard userId != nil else { return }
        if simulatedFlaggedChatIds.contains(chatId) {
            simulatedFlaggedChatIds.remove(chatId)
        } else {
            simulatedFlaggedChatIds.insert(chatId)
        }
    }

    func clearSimulatedFlags() {
        simulatedFlaggedChatIds.removeAll()
    }
    #endif

    private func clear() {
        #if DEBUG
        simulatedFlaggedChatIds = []
        #endif
        clearReport()
    }

    private func clearReport() {
        generation = UUID()
        request?.cancel()
        request = nil
        flaggedChatIds = []
        report = nil
        errorMessage = nil
        isLoading = false
    }
}
