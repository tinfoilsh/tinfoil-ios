//
//  ProjectModels.swift
//  TinfoilChat
//
//  Models for webapp-compatible Projects.
//

import Foundation

struct MemoryFact: Codable, Identifiable, Equatable {
    let id: String
    var fact: String
    var date: String
    var category: String
    var confidence: Double
}

struct Project: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    var systemInstructions: String
    var memory: [MemoryFact]
    var createdAt: String
    var updatedAt: String
    var syncVersion: Int
    var decryptionFailed: Bool?
}

struct ProjectData: Codable, Equatable {
    var name: String
    var description: String
    var systemInstructions: String
    var memory: [MemoryFact]
}

struct CreateProjectData: Codable, Equatable {
    var name: String
    var description: String = ""
    var systemInstructions: String = ""
}

struct UpdateProjectData: Codable, Equatable {
    var name: String?
    var description: String?
    var systemInstructions: String?
    var memory: [MemoryFact]?
}

struct ProjectDocument: Codable, Identifiable, Equatable {
    let id: String
    let projectId: String
    var filename: String
    var contentType: String
    var sizeBytes: Int
    var syncVersion: Int
    var createdAt: String
    var updatedAt: String
    var content: String?
    var decryptionFailed: Bool?
}

struct ProjectDocumentPayload: Codable, Equatable {
    var content: String
    var filename: String
    var contentType: String
}

struct ProjectChat: Codable, Identifiable, Equatable {
    let id: String
    let projectId: String
    let messageCount: Int?
    let syncVersion: Int?
    let size: Int?
    let formatVersion: Int?
    let createdAt: String
    let updatedAt: String
    let content: String?
}

struct GenerateProjectIdResponse: Codable {
    let projectId: String
    let timestamp: String
    let reverseTimestamp: Int
}

struct GenerateDocumentIdResponse: Codable {
    let documentId: String
    let timestamp: String
    let reverseTimestamp: Int
}

struct ProjectListResponse: Codable {
    let projects: [ProjectListItem]
    let nextContinuationToken: String?
    let hasMore: Bool
}

struct ProjectListItem: Codable, Identifiable {
    let id: String
    let key: String?
    let createdAt: String
    let updatedAt: String
    let syncVersion: Int
    let size: Int?
    let content: String?
}

struct ProjectDocumentListResponse: Codable {
    let documents: [ProjectDocumentListItem]
}

struct ProjectDocumentListItem: Codable, Identifiable {
    let id: String
    let projectId: String
    let sizeBytes: Int?
    let syncVersion: Int
    let createdAt: String
    let updatedAt: String
    let content: String?
}

struct ProjectChatListResponse: Codable {
    let chats: [RemoteChat]
    let hasMore: Bool?
    let nextContinuationToken: String?
}

struct ProjectSyncStatus: Codable, Equatable {
    let count: Int
    let lastUpdated: String?
}

typealias ProjectChatSyncStatus = ProjectSyncStatus
typealias ProjectDocumentSyncStatus = ProjectSyncStatus


