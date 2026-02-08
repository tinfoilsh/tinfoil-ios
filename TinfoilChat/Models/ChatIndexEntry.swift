//
//  ChatIndexEntry.swift
//  TinfoilChat
//
//  Lightweight metadata for the chat index, used for sidebar rendering,
//  pagination, sync queries, and filtering without loading full chat data.
//

import Foundation

struct ChatIndexEntry: Codable, Identifiable {
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
    var userId: String?
    var language: String?

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
        self.userId = chat.userId
        self.language = chat.language
    }
}
