import Testing
@testable import TinfoilChat

@Suite("Personalization prompt")
struct PersonalizationPromptTests {
    @Test("requires Personalize responses to be enabled")
    func requiresEnabledFlag() {
        let prompt = PersonalizationPromptBuilder.build(
            isEnabled: false,
            nickname: "Ada",
            profession: "Engineer",
            traits: ["direct"],
            additionalContext: "Use examples"
        )

        #expect(prompt == nil)
    }

    @Test("includes saved details when enabled")
    func includesSavedDetails() throws {
        let prompt = try #require(PersonalizationPromptBuilder.build(
            isEnabled: true,
            nickname: " Ada ",
            profession: "Engineer",
            traits: ["direct", "  "],
            additionalContext: "Use examples"
        ))

        #expect(prompt.contains("<nickname>Ada</nickname>"))
        #expect(prompt.contains("<profession>Engineer</profession>"))
        #expect(prompt.contains("<trait>direct</trait>"))
        #expect(prompt.contains("<additional_context>\n    Use examples\n  </additional_context>"))
    }

    @Test("escapes every user-controlled XML text node")
    func escapesUserControlledValues() throws {
        let prompt = try #require(PersonalizationPromptBuilder.build(
            isEnabled: true,
            nickname: "A & B",
            profession: "<Engineer>",
            traits: ["direct </trait>"],
            additionalContext: "Use \"examples\" & 'quotes'"
        ))

        #expect(prompt.contains("<nickname>A &amp; B</nickname>"))
        #expect(prompt.contains("<profession>&lt;Engineer&gt;</profession>"))
        #expect(prompt.contains("<trait>direct &lt;/trait&gt;</trait>"))
        #expect(prompt.contains("Use &quot;examples&quot; &amp; &apos;quotes&apos;"))
    }
}
