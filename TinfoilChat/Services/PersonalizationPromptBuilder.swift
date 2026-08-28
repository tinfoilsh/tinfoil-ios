import Foundation

enum PersonalizationPromptBuilder {
    static func build(
        isEnabled: Bool,
        nickname: String,
        profession: String,
        traits: [String],
        additionalContext: String
    ) -> String? {
        guard isEnabled else { return nil }

        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProfession = profession.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyTraits = traits.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let trimmedContext = additionalContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAnyField = !trimmedNickname.isEmpty
            || !trimmedProfession.isEmpty
            || !nonEmptyTraits.isEmpty
            || !trimmedContext.isEmpty

        guard hasAnyField else { return nil }

        var xml = "The user has provided personal preferences for this conversation. Adapt your responses according to these settings while maintaining accuracy and helpfulness.\n\n<user_preferences>"

        if !trimmedNickname.isEmpty {
            xml += "\n  <nickname>\(escapeXML(trimmedNickname))</nickname>"
        }

        if !trimmedProfession.isEmpty {
            xml += "\n  <profession>\(escapeXML(trimmedProfession))</profession>"
        }

        if !nonEmptyTraits.isEmpty {
            xml += "\n  <traits>"
            for trait in nonEmptyTraits {
                xml += "\n    <trait>\(escapeXML(trait))</trait>"
            }
            xml += "\n  </traits>"
        }

        if !trimmedContext.isEmpty {
            xml += "\n  <additional_context>\n    \(escapeXML(trimmedContext))\n  </additional_context>"
        }

        xml += "\n</user_preferences>"
        return xml
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
