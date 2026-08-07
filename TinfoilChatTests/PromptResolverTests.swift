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
    func presetTakesPrecedenceOverCustomAndDefaultPrompts() throws {
        let resolved = try PromptResolver.resolve(
            presetId: preset.id,
            availablePresets: [preset],
            profileCustomPrompt: "profile prompt",
            settingsCustomPrompt: "settings prompt",
            defaultPrompt: "default prompt"
        )

        #expect(resolved == ResolvedSystemPrompt(
            systemPrompt: "preset prompt",
            suppressDefaultRules: false
        ))
    }

    @Test
    func unresolvedPresetDoesNotFallThrough() {
        #expect(throws: PromptResolutionError.presetUnavailable("user:missing")) {
            try PromptResolver.resolve(
                presetId: "user:missing",
                availablePresets: [preset],
                profileCustomPrompt: "profile prompt",
                settingsCustomPrompt: "settings prompt",
                defaultPrompt: "default prompt"
            )
        }
    }

    @Test
    func customAndDefaultPrecedenceIsPreserved() throws {
        let profile = try PromptResolver.resolve(
            presetId: nil,
            availablePresets: [],
            profileCustomPrompt: "profile prompt",
            settingsCustomPrompt: "settings prompt",
            defaultPrompt: "default prompt"
        )
        let fallback = try PromptResolver.resolve(
            presetId: nil,
            availablePresets: [],
            profileCustomPrompt: nil,
            settingsCustomPrompt: nil,
            defaultPrompt: "default prompt"
        )

        #expect(profile.systemPrompt == "profile prompt")
        #expect(fallback.systemPrompt == "default prompt")
    }
}
