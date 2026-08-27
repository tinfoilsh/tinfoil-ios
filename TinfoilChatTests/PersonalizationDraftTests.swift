import Testing
@testable import TinfoilChat

@Suite("Personalization drafts")
@MainActor
struct PersonalizationDraftTests {
    @Test("delayed load cannot replace a draft captured for save")
    func delayedLoadDoesNotReplaceSavedDraft() async {
        let editor = PersonalizationEditorState(draft: .defaults)
        let loadGeneration = editor.beginLoad()
        editor.traits = ["direct"]
        editor.additionalContext = "Prefer short examples"
        let savedDraft = editor.draft

        await Task.yield()
        let applied = editor.applyLoadedDraft(
            PersonalizationDraft(
                isEnabled: true,
                nickname: "Remote",
                profession: "Researcher",
                traits: ["formal"],
                additionalContext: "Remote context"
            ),
            generation: loadGeneration
        )

        #expect(applied == false)
        #expect(editor.draft == savedDraft)
    }

    @Test("trait and context edits dirty their profile clocks")
    func traitAndContextEditsAreTracked() {
        var draft = PersonalizationDraft.defaults
        draft.traits = ["thoughtful"]
        draft.additionalContext = "Explain tradeoffs"

        #expect(Set(draft.changedProfileFields(comparedTo: .defaults)) == Set([
            "traits", "additionalContext",
        ]))
    }
}
