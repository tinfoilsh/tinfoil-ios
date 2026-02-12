//
//  ChatIndexEntry.swift
//  TinfoilChat
//
//  Lightweight metadata for the chat index, used for sidebar rendering,
//  pagination, sync queries, and filtering without loading full chat data.
//

import Foundation

struct ChatIndexEntry: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var titleState: Chat.TitleState
    var createdAt: Date
    var updatedAt: Date
    var modelType: ModelType?
    var messageCount: Int
    var decryptionFailed: Bool
    var dataCorrupted: Bool
    var hasEncryptedData: Bool
    var projectId: String?
    var syncVersion: Int
    var syncedAt: Date?
    var locallyModified: Bool
    var isLocalOnly: Bool
    var userId: String?
    var language: String?

    /// Whether this entry represents a chat worth showing in the sidebar
    var isDisplayable: Bool {
        projectId == nil && (messageCount > 0 || decryptionFailed || titleState != .placeholder)
    }

    /// Whether this entry is a cloud-synced (non-local) displayable chat
    var isCloudDisplayable: Bool {
        isDisplayable && !isLocalOnly
    }

    init(from chat: Chat) {
        self.id = chat.id
        self.title = chat.title
        self.titleState = chat.titleState
        self.createdAt = chat.createdAt
        self.updatedAt = chat.updatedAt
        self.modelType = chat.modelType
        self.messageCount = chat.messages.count
        self.decryptionFailed = chat.decryptionFailed
        self.dataCorrupted = chat.dataCorrupted
        self.hasEncryptedData = chat.encryptedData != nil
        self.projectId = chat.projectId
        self.syncVersion = chat.syncVersion
        self.syncedAt = chat.syncedAt
        self.locallyModified = chat.locallyModified
        self.isLocalOnly = chat.isLocalOnly
        self.userId = chat.userId
        self.language = chat.language
    }
}
