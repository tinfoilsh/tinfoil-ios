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
        var context = "## Project: \(project.name)\n"

        if !project.description.isEmpty {
            context += "\n\(project.description)\n"
        }

        if !project.systemInstructions.isEmpty {
            context += "\n### Instructions\n\(project.systemInstructions)\n"
        }

        let documentsWithContent = documents.filter { ($0.content?.isEmpty == false) }
        if !documentsWithContent.isEmpty {
            context += "\n### Documents\n"
            for document in documentsWithContent {
                context += "--- \(document.filename) ---\n\(document.content ?? "")\n\n"
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
}
