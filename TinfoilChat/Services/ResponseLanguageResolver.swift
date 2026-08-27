import Foundation

enum ResponseLanguageResolver {
    static let systemSelection = "System"
    static let systemDisplayName = "System (device language)"

    static func displayName(for selection: String) -> String {
        selection == systemSelection ? systemDisplayName : selection
    }

    static func resolve(
        profileLanguage: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let selection = explicitSelection(profileLanguage) ?? systemSelection

        guard selection == systemSelection else { return selection }
        guard let preferredLanguage = preferredLanguages.first else { return "English" }

        return Locale(identifier: "en").localizedString(forIdentifier: preferredLanguage)
            ?? preferredLanguage
    }

    private static func explicitSelection(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
