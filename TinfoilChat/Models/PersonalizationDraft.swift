import Combine
import Foundation

struct PersonalizationDraft: Equatable {
    var isEnabled: Bool
    var nickname: String
    var profession: String
    var traits: [String]
    var additionalContext: String

    static let defaults = PersonalizationDraft(
        isEnabled: ProfileDefaults.isUsingPersonalization,
        nickname: ProfileDefaults.nickname,
        profession: ProfileDefaults.profession,
        traits: ProfileDefaults.traits,
        additionalContext: ProfileDefaults.additionalContext
    )
}

@MainActor
final class PersonalizationEditorState: ObservableObject {
    @Published var isEnabled: Bool { didSet { registerEdit() } }
    @Published var nickname: String { didSet { registerEdit() } }
    @Published var profession: String { didSet { registerEdit() } }
    @Published var traits: [String] { didSet { registerEdit() } }
    @Published var additionalContext: String { didSet { registerEdit() } }

    private(set) var generation = 0
    private var baselineGeneration = 0
    private var isApplyingLoadedDraft = false

    init(draft: PersonalizationDraft = .defaults) {
        isEnabled = draft.isEnabled
        nickname = draft.nickname
        profession = draft.profession
        traits = draft.traits
        additionalContext = draft.additionalContext
    }

    var draft: PersonalizationDraft {
        PersonalizationDraft(
            isEnabled: isEnabled,
            nickname: nickname,
            profession: profession,
            traits: traits,
            additionalContext: additionalContext
        )
    }

    func beginLoad() -> Int {
        generation
    }

    @discardableResult
    func applyLoadedDraft(_ draft: PersonalizationDraft, generation loadGeneration: Int) -> Bool {
        guard loadGeneration == generation else { return false }
        apply(draft)
        baselineGeneration = generation
        return true
    }

    @discardableResult
    func applyRefreshedDraft(_ draft: PersonalizationDraft) -> Bool {
        guard generation == baselineGeneration else { return false }
        apply(draft)
        baselineGeneration = generation
        return true
    }

    private func apply(_ draft: PersonalizationDraft) {
        isApplyingLoadedDraft = true
        isEnabled = draft.isEnabled
        nickname = draft.nickname
        profession = draft.profession
        traits = draft.traits
        additionalContext = draft.additionalContext
        isApplyingLoadedDraft = false
    }

    func clearDetails() {
        isApplyingLoadedDraft = true
        nickname = ""
        profession = ""
        traits = []
        additionalContext = ""
        isApplyingLoadedDraft = false
        generation += 1
    }

    private func registerEdit() {
        guard !isApplyingLoadedDraft else { return }
        generation += 1
    }
}
