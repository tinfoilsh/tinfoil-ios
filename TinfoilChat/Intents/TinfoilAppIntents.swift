//
//  TinfoilAppIntents.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import AppIntents

/// Asks a question by voice or text. Siri collects the prompt, the app opens,
/// starts a new chat, and sends the message.
struct AskTinfoilIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Tinfoil"
    static let description = IntentDescription(
        "Starts a new private chat and sends your question.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Prompt", requestValueDialog: "What would you like to ask?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentCoordinator.shared.enqueue(.askQuestion(prompt))
        return .result()
    }
}

/// Opens the app with a fresh chat ready for input.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start New Chat"
    static let description = IntentDescription(
        "Opens Tinfoil with a fresh private chat.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentCoordinator.shared.enqueue(.newChat)
        return .result()
    }
}

/// Opens the app and immediately starts recording a voice message.
struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Dictation"
    static let description = IntentDescription(
        "Opens Tinfoil and starts recording a voice message.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentCoordinator.shared.enqueue(.startDictation)
        return .result()
    }
}

/// Registers Siri phrases so the intents work by voice without any setup,
/// and surfaces them in Spotlight, the Shortcuts app, and the Action button.
struct TinfoilAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskTinfoilIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask a question in \(.applicationName)"
            ],
            shortTitle: "Ask Tinfoil",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat",
                "Create a new chat in \(.applicationName)"
            ],
            shortTitle: "New Chat",
            systemImageName: "plus.bubble"
        )
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation in \(.applicationName)",
                "Dictate to \(.applicationName)",
                "Start voice input in \(.applicationName)"
            ],
            shortTitle: "Voice Dictation",
            systemImageName: "mic"
        )
    }
}
