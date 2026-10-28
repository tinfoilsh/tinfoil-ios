import Foundation

enum ResponseLanguageResolver {
    static let systemSelection = "System"
    static let systemDisplayName = "System"

    static func normalizedSelection(_ value: String?) -> String {
        guard let value else { return systemSelection }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? systemSelection : trimmed
    }

    static func displayName(for selection: String?) -> String {
        let selection = normalizedSelection(selection)
        return selection == systemSelection ? systemDisplayName : selection
    }
}
