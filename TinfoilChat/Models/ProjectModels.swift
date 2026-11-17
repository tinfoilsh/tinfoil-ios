//
//  ProjectModels.swift
//  TinfoilChat
//
//  Projects as the views show them, from what the chat service stores.
//

import Foundation

struct Project: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var color: String?
    var description: String
    var systemInstructions: String
    /// When the harness dated the project, if it did.
    var createdAt: String?
    var updatedAt: String?

    init(_ project: Components.Schemas.Project) {
        id = project.id
        name = project.name
        color = project.color
        description = project.description
        systemInstructions = project.systemInstructions
        createdAt = project.createdAt
        updatedAt = project.updatedAt
    }

    init(_ project: ProjectView) {
        id = project.id
        name = project.name
        color = project.color
        description = project.description
        systemInstructions = project.systemInstructions
        createdAt = project.createdAt
        updatedAt = project.updatedAt
    }
}

struct ProjectDocument: Identifiable, Equatable {
    let id: String
    let projectId: String
    var filename: String
    var contentType: String
    var sizeBytes: Int
    var createdAt: String?
    var updatedAt: String?
    var content: String?
    var thumbnailBase64: String?
    /// Whether the chat service keeps the file the document was read from.
    /// One stored before files were kept has only its text.
    var hasFile: Bool

    /// The extensions of the names a document's text is saved under as it
    /// is.
    private static let textFileExtensions = [".md", ".txt"]
    private static let markdownExtension = ".md"

    init(_ document: Components.Schemas.ProjectDocument) {
        id = document.id
        projectId = document.projectId
        filename = document.filename
        contentType = document.contentType
        sizeBytes = document.sizeBytes
        createdAt = document.createdAt
        updatedAt = document.updatedAt
        content = document.content
        thumbnailBase64 = document.thumbnailBase64
        hasFile = document.hasFile == true
    }

    /// The name a document's text is saved under when no file of it is
    /// kept: its own when that names a text file already, and its own as
    /// Markdown otherwise.
    var textFileName: String {
        let name = ExportedFile.fileName(filename)
        let lowercased = name.lowercased()
        if Self.textFileExtensions.contains(where: { lowercased.hasSuffix($0) }) { return name }
        return name + Self.markdownExtension
    }
}
