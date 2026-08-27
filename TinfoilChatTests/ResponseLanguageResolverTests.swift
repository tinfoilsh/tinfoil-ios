import Testing
@testable import TinfoilChat

@Suite("Response language resolution")
struct ResponseLanguageResolverTests {
    @Test("missing selections use the device language")
    func missingSelectionUsesDeviceLanguage() {
        let resolved = ResponseLanguageResolver.resolve(
            chatLanguage: nil,
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
            chatLanguage: ResponseLanguageResolver.systemSelection,
            profileLanguage: "Spanish",
            preferredLanguages: ["de"]
        )

        #expect(resolved == "German")
    }

    @Test("explicit chat and profile values are preserved")
    func preservesExplicitValues() {
        let chatSelection = ResponseLanguageResolver.resolve(
            chatLanguage: "Portuguese",
            profileLanguage: "Spanish",
            preferredLanguages: ["de"]
        )
        let profileSelection = ResponseLanguageResolver.resolve(
            chatLanguage: nil,
            profileLanguage: "Spanish",
            preferredLanguages: ["de"]
        )

        #expect(chatSelection == "Portuguese")
        #expect(profileSelection == "Spanish")
    }
}
