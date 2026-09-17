import Testing
@testable import TinfoilChat

struct PromptResolverTests {
    private let preset = PromptPreset(
        id: "user:shared-preset",
        name: "Shared",
        description: "",
        iconName: "square.and.pencil",
        systemPrompt: "preset prompt",
        isBuiltIn: false
    )

    @Test
    func presetTakesPrecedenceOverDefaultPrompt() throws {
        let resolved = try PromptResolver.resolve(
            presetId: preset.id,
            availablePresets: [preset],
            defaultPrompt: "default prompt"
        )

        #expect(resolved == "preset prompt")
    }

    @Test
    func unresolvedPresetDoesNotFallThrough() {
        #expect(throws: PromptResolutionError.presetUnavailable("user:missing")) {
            try PromptResolver.resolve(
                presetId: "user:missing",
                availablePresets: [preset],
                defaultPrompt: "default prompt"
            )
        }
    }

    @Test
    func fallsBackToDefaultWithoutPreset() throws {
        let resolved = try PromptResolver.resolve(
            presetId: nil,
            availablePresets: [preset],
            defaultPrompt: "default prompt"
        )

        #expect(resolved == "default prompt")
    }
}
