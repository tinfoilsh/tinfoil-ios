//
//  ProjectModels.swift
//  TinfoilChat
//
//  Projects as the views show them, from what the chat service stores.
//

import Foundation

struct Project: Identifiable, Equatable {
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
    }
}
