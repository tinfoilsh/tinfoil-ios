//
//  ChatListSummary.swift
//  TinfoilChat
//

import Foundation

/// A chat as a list row shows it.
struct ChatListSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let activityAt: Date
    var projectId: String?
    let isLocalOnly: Bool
    let isBlankChat: Bool
    let isTemporary: Bool
    let pendingSave: Bool
    let isRunning: Bool

    init(from chat: Chat) {
        id = chat.id
        title = chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt ?? chat.createdAt
        activityAt = chat.lastActivity
        projectId = chat.projectId
        isLocalOnly = chat.isLocalOnly
        isBlankChat = chat.isBlankChat
        isTemporary = chat.isTemporary
        pendingSave = chat.pendingSave
        isRunning = chat.activeRun != nil
    }
}
