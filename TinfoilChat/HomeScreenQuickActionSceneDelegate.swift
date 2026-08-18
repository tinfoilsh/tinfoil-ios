//
//  HomeScreenQuickActionSceneDelegate.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import UIKit

@MainActor
final class HomeScreenQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
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
