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
    var formatVersion: Int?
    var projectId: String?
    var projectLocallyModified: Bool?
    var syncVersion: Int
    var syncedAt: Date?
    var locallyModified: Bool
    var isLocalOnly: Bool = false
    var userId: String?
    var language: String?
    var hasPendingRecoveries: Bool?

    /// Whether this entry represents a chat worth showing in the sidebar
    var isDisplayable: Bool {
        projectId == nil && (messageCount > 0 || decryptionFailed || titleState != .placeholder)
    }

    /// Whether this entry is a cloud-synced (non-local) displayable chat
    var isCloudDisplayable: Bool {
        isDisplayable && !isLocalOnly
    }

    var needsCloudUpload: Bool {
        !isLocalOnly
            && locallyModified
            && messageCount > 0
            && !decryptionFailed
            && !dataCorrupted
    }

    var requiresCloudDelete: Bool {
        !isLocalOnly && (syncedAt != nil || syncVersion > 0)
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
        self.formatVersion = chat.formatVersion
        self.projectId = chat.projectId
        self.projectLocallyModified = chat.projectLocallyModified
        self.syncVersion = chat.syncVersion
        self.syncedAt = chat.syncedAt
        self.locallyModified = chat.locallyModified
        self.isLocalOnly = chat.isLocalOnly
        self.userId = chat.userId
        self.language = chat.language
        self.hasPendingRecoveries = chat.pendingRecoveries?.isEmpty == false
    }
}
