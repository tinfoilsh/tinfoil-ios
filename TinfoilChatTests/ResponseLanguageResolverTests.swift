import Testing
@testable import TinfoilChat

@Suite("Response language resolution")
struct ResponseLanguageResolverTests {
    @Test("missing selections use the device language")
    func missingSelectionUsesDeviceLanguage() {
        let resolved = ResponseLanguageResolver.resolve(
            profileLanguage: nil,
            preferredLanguages: ["fr"]
        )

        #expect(ProfileDefaults.language == ResponseLanguageResolver.systemSelection)
        #expect(resolved == "French")
        #expect(resolved != ResponseLanguageResolver.systemSelection)
    }

    @Test("System resolves at send time")
    func systemResolvesAtSendTime() {
        let resolved = ResponseLanguageResolver.resolve(
            profileLanguage: ResponseLanguageResolver.systemSelection,
            preferredLanguages: ["de"]
        )

        #expect(resolved == "German")
    }

    @Test("blank selections normalize to System for display and selection")
    func blankSelectionNormalizesToSystem() {
        let normalized = ResponseLanguageResolver.normalizedSelection("  \n")

        #expect(normalized == ResponseLanguageResolver.systemSelection)
        #expect(ResponseLanguageResolver.displayName(for: "  ") == ResponseLanguageResolver.systemDisplayName)
    }

    @Test("explicit profile values are preserved")
    func preservesExplicitValues() {
        let profileSelection = ResponseLanguageResolver.resolve(
            profileLanguage: "Spanish",
            preferredLanguages: ["de"]
        )

        #expect(profileSelection == "Spanish")
    }

    @Test("changing the profile language affects the current chat")
    func currentChatUsesChangedProfileLanguage() {
        let initial = ResponseLanguageResolver.resolve(
            profileLanguage: "English",
            preferredLanguages: ["de"]
        )
        let changed = ResponseLanguageResolver.resolve(
            profileLanguage: "Japanese",
            preferredLanguages: ["de"]
        )

        #expect(initial == "English")
        #expect(changed == "Japanese")
    }
}
