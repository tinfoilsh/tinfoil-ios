//
//  PrivacyCover.swift
//  TinfoilChat
//
//  Keeps chats and keys off the screen when the app is not in use: the
//  app switcher and the snapshot iOS takes as the app leaves show a cover,
//  and key views are hidden while the screen is recorded or shared.
//

import SwiftUI
import UIKit

/// Covers each window scene, sheets included, while it is not active.
@MainActor
final class PrivacyCover {
    static let shared = PrivacyCover()

    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated { self?.cover(scene) }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated { self?.uncover(scene) }
            },
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated { self?.release(scene) }
            },
        ]
    }

    private func cover(_ scene: UIWindowScene?) {
        guard let scene else { return }
        let window = windows[ObjectIdentifier(scene)] ?? makeWindow(for: scene)
        window.isHidden = false
    }

    private func uncover(_ scene: UIWindowScene?) {
        guard let scene else { return }
        windows[ObjectIdentifier(scene)]?.isHidden = true
    }

    private func release(_ scene: UIWindowScene?) {
        guard let scene else { return }
        windows[ObjectIdentifier(scene)]?.isHidden = true
        windows[ObjectIdentifier(scene)] = nil
    }

    private func makeWindow(for scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: PrivacyCoverView())
        windows[ObjectIdentifier(scene)] = window
        return window
    }
}

/// The app's logo on its launch background.
private struct PrivacyCoverView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.backgroundPrimary : Color.white)
                .ignoresSafeArea()
            Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                .resizable()
                .scaledToFit()
                .frame(height: Constants.Privacy.coverLogoHeight)
                .accessibilityHidden(true)
        }
    }
}

/// Hides the content behind a placeholder while the screen is recorded,
/// mirrored or shared.
private struct ConcealedWhileCaptured: ViewModifier {
    @State private var captured = Self.screenCaptured

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(captured)
            .overlay {
                if captured {
                    Label(Constants.Privacy.concealedLabel, systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(Constants.Privacy.concealedLabelMinimumScale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.secondarySystemBackground))
                        .accessibilityLabel(Constants.Privacy.concealedAccessibilityLabel)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                captured = Self.screenCaptured
            }
    }

    private static var screenCaptured: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .contains { $0.isCaptured }
    }
}

extension View {
    /// Hides a key or other secret while the screen is recorded or shared.
    func concealedWhileCaptured() -> some View {
        modifier(ConcealedWhileCaptured())
    }
}
