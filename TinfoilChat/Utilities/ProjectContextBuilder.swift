//
//  ProjectContextBuilder.swift
//  TinfoilChat
//
//  Builds project context using the webapp-compatible prompt format.
//

import Foundation

enum ProjectContextBuilder {
    static func estimateTokenCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.count) / 4.0))
    }

    static func build(project: Project, documents: [ProjectDocument]) -> String {
        var context = "## Project: \(escape(project.name))\n"

        if !project.description.isEmpty {
            context += "\n\(escape(project.description))\n"
        }

        if !project.systemInstructions.isEmpty {
            context += "\n### Instructions\n\(escape(project.systemInstructions))\n"
        }

        let documentsWithContent = documents.filter { ($0.content?.isEmpty == false) }
        if !documentsWithContent.isEmpty {
            context += "\n### Documents\n"
            for document in documentsWithContent {
                let safeFilename = escape(document.filename)
                let safeContent = escape(document.content ?? "")
                context += "--- \(safeFilename) ---\n\(safeContent)\n\n"
            }
        }

        return context
    }

    static func applyProjectContext(to baseSystemPrompt: String, project: Project?, documents: [ProjectDocument]) -> String {
        guard let project else { return baseSystemPrompt }

        let projectContext = build(project: project, documents: documents)
        guard !projectContext.isEmpty else { return baseSystemPrompt }

        return "\(baseSystemPrompt)\n\n<project_context>\n\(projectContext)\n</project_context>"
    }

    /// Escape `&`, `<`, and `>` so no tag inside user-supplied project text
    /// or an uploaded document can close the `<project_context>` block and be
    /// read as top-level instructions. Matches the webapp's escaping.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
