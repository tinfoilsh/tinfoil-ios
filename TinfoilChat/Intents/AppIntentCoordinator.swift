//
//  AppIntentCoordinator.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import Foundation

/// Buffers actions requested by App Intents (Siri, Shortcuts, Action button)
/// until the chat UI is ready to perform them. Intents run before or while
/// the app is foregrounding, so the live ChatViewModel may not exist yet.
@MainActor
final class AppIntentCoordinator: ObservableObject {
    static let shared = AppIntentCoordinator()

    enum Action: Equatable {
        case askQuestion(String)
        case newChat
        case startDictation
    }

    @Published private(set) var pendingAction: Action?

    private init() {}

    func enqueue(_ action: Action) {
        pendingAction = action
    }

    func consumePendingAction() -> Action? {
        defer { pendingAction = nil }
        return pendingAction
    }
}
