//
//  HomeScreenQuickActionSceneDelegate.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import UIKit

@MainActor
final class HomeScreenQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    static func refreshQuickActions(hasPremiumAccess: Bool) {
        var items = [
            UIApplicationShortcutItem(
                type: Constants.HomeScreenQuickActions.newChat,
                localizedTitle: "New Chat",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: Constants.HomeScreenQuickActions.favorites,
                localizedTitle: "Favorites",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "pin"),
                userInfo: nil
            ),
        ]
        if hasPremiumAccess {
            items.insert(
                UIApplicationShortcutItem(
                    type: Constants.HomeScreenQuickActions.projects,
                    localizedTitle: "Projects",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "folder"),
                    userInfo: nil
                ),
                at: 1
            )
        }
        UIApplication.shared.shortcutItems = items
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        _ = handle(shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handle(shortcutItem))
    }

    private func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        let action: AppIntentCoordinator.Action

        switch shortcutItem.type {
        case Constants.HomeScreenQuickActions.newChat:
            action = .newChat
        case Constants.HomeScreenQuickActions.projects:
            guard PremiumProjectPolicy.hasAccess(
                isAuthenticated: UserDefaults.standard.bool(forKey: Constants.StorageKeys.Auth.state),
                hasActiveSubscription: UserDefaults.standard.bool(forKey: Constants.StorageKeys.Auth.subscription)
            ) else { return false }
            action = .showProjects
        case Constants.HomeScreenQuickActions.favorites:
            action = .showFavorites
        default:
            return false
        }

        AppIntentCoordinator.shared.enqueue(action)
        return true
    }
}
