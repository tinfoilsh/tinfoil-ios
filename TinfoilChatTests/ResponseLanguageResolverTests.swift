import Testing
@testable import TinfoilChat

@Suite("Response language resolution")
struct ResponseLanguageResolverTests {
    @Test("blank selections normalize to System for display and selection")
    func blankSelectionNormalizesToSystem() {
        let normalized = ResponseLanguageResolver.normalizedSelection("  \n")

        #expect(normalized == ResponseLanguageResolver.systemSelection)
        #expect(ResponseLanguageResolver.displayName(for: "  ") == ResponseLanguageResolver.systemDisplayName)
    }
}
