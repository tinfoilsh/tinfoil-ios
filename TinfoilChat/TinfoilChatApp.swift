//
//  TinfoilChatApp.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import Sentry
import RevenueCat

import UIKit
import Clerk

@main
struct TinfoilChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var clerk = Clerk.shared
    @StateObject private var appConfig = AppConfig.shared
    @StateObject private var authManager = AuthManager()
    @State private var isClerkConfigured = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appConfig.isInitialized {
                    if appConfig.isAppVersionSupported {
                        AdaptiveTintContainer {
                            ContentView()
                                .environment(clerk)
                                .environmentObject(authManager)
                        }
                            .onOpenURL { url in
                                // Handle URL redirects from authentication
                                // Immediately check auth state when app reopens from OAuth
                                Task {
                                    do {
                                        try await clerk.load()
                                        if clerk.user != nil {
                                            await authManager.initializeAuthState()
                                            // Post immediate completion notification
                                            NotificationCenter.default.post(name: NSNotification.Name("AuthenticationCompleted"), object: nil)
                                            NotificationCenter.default.post(name: NSNotification.Name("CheckAuthState"), object: nil)
                                        }
                                    } catch {
                                        // Fallback to the slower checking method
                                        NotificationCenter.default.post(name: NSNotification.Name("CheckAuthState"), object: nil)
                                    }
                                }
                            }
                            .task {
                            // Configure Clerk only once
                            if !isClerkConfigured {
                                clerk.configure(publishableKey: AppConfig.shared.clerkPublishableKey)
                                isClerkConfigured = true
                                
                                // Pass the clerk instance to auth manager
                                authManager.setClerk(clerk)
                                
                                do {
                                    try await clerk.load()
                                    
                                    // Initialize authentication state
                                    await authManager.initializeAuthState()
                                    
                                    // Initialize cloud sync services (sets robust token getter for profile sync)
                                    do {
                                        try await CloudSyncService.shared.initialize()
                                    } catch {
                                        #if DEBUG
                                        print("Failed to initialize CloudSyncService: \(error)")
                                        #endif
                                    }
                                    
                                    // Initialize ProfileManager to start auto-sync
                                    _ = ProfileManager.shared
                                    // Kick off an initial profile sync now that auth and token getter are ready
                                    await ProfileManager.shared.performFullSync()
                                    
                                    // Add observer for Clerk auth state changes
                                    NotificationCenter.default.addObserver(
                                        forName: NSNotification.Name("ClerkUserChanged"),
                                        object: nil,
                                        queue: .main
                                    ) { _ in
                                        Task {
                                            await authManager.initializeAuthState()
                                            // Sync profile when auth state changes
                                            await ProfileManager.shared.performFullSync()
                                        }
                                    }
                                } catch {
                                }
                            
                            }
                        }
                    } else {
                        UpdateRequiredView()
                    }
                } else if let error = appConfig.initializationError {
                    if !appConfig.networkMonitor.isConnected {
                        NoInternetView {
                            Task {
                                await appConfig.loadRemoteConfig()
                            }
                        }
                    } else {
                        VStack {
                            Text("Failed to Initialize")
                                .font(.title)
                                .padding()
                            Text(error.localizedDescription)
                                .multilineTextAlignment(.center)
                                .padding()
                            Button("Retry") {
                                Task {
                                    await appConfig.loadRemoteConfig()
                                }
                            }
                        }
                        .onAppear {
                        }
                    }
                } else {
                    LoadingScreen()
                }
            }
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configure RevenueCat
        RevenueCatManager.shared.configure(apiKey: "appl_NsqQinGVxyvuivFgGKjKcIqHlsk")

        // Configure Sentry
        SentrySDK.start { options in
            options.dsn = "https://6f1fb6f77a16359e4d05acd52bbb2b93@o4509288836694016.ingest.us.sentry.io/4509290148069376"
            options.tracesSampleRate = 1.0
            options.enableAutoSessionTracking = true
            // Disable PII collection for privacy
            // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
            options.sendDefaultPii = false

            // Configure profiling. Visit https://docs.sentry.io/platforms/apple/profiling/ to learn more.
            options.configureProfiling = { profileOptions in
                profileOptions.sessionSampleRate = 1.0
                profileOptions.lifecycle = .trace
            }

            // We only enable stack traces (anonymized) for privacy
            // Uncomment the following lines to add more data to your events
            // options.attachScreenshot = true // This adds a screenshot to the error events
            // options.attachViewHierarchy = true // This adds the view hierarchy to the error events
        }

        return true
    }

    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session
    }
}

// MARK: - Adaptive Tint Container
struct AdaptiveTintContainer<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .tint(colorScheme == .dark ? .white : .black)
    }
}

// MARK: - Loading Screen
struct LoadingScreen: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.backgroundPrimary : Color.white)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 48)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .gray))
                    .scaleEffect(1.2)
            }
        }
    }
}
