//
//  ChatListSummary.swift
//  TinfoilChat
//

import Foundation

struct ChatListSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let projectId: String?
    let isLocalOnly: Bool
    let decryptionFailed: Bool
    let isBlankChat: Bool
    let isTemporary: Bool

    init(from chat: Chat) {
        id = chat.id
        title = chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        projectId = chat.projectId
        isLocalOnly = chat.isLocalOnly
        decryptionFailed = chat.decryptionFailed
        isBlankChat = chat.isBlankChat
        isTemporary = chat.isTemporary
    }

    init(from entry: ChatIndexEntry) {
        id = entry.id
        title = entry.title
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        projectId = entry.projectId
        isLocalOnly = entry.isLocalOnly
        decryptionFailed = entry.decryptionFailed
        isBlankChat = entry.messageCount == 0 && !entry.decryptionFailed
        isTemporary = false
    }
}
