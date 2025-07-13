//
//  TinfoilChatApp.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI
import Sentry

import UIKit
import Clerk

@main
struct TinfoilChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var clerk = Clerk.shared
    @StateObject private var appConfig = AppConfig.shared
    @StateObject private var authManager = AuthManager()
    @State private var isClerkConfigured = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appConfig.isInitialized {
                    if appConfig.isAppVersionSupported {
                        ContentView()
                            .environment(clerk)
                            .environmentObject(authManager)
                            .accentColor(Color.accentPrimary)
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
                                    
                                    // Add observer for Clerk auth state changes
                                    NotificationCenter.default.addObserver(
                                        forName: NSNotification.Name("ClerkUserChanged"),
                                        object: nil,
                                        queue: .main
                                    ) { _ in
                                        Task {
                                            await authManager.initializeAuthState()
                                        }
                                    }
                                } catch {
                                    print("Tinfoil: Failed to load Clerk: \(error)")
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
                    ZStack {
                        (colorScheme == .dark ? Color(hex: "111827") : Color.white)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .black))
                                .scaleEffect(1.5)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configure Sentry
        SentrySDK.start { options in
            options.dsn = "https://6f1fb6f77a16359e4d05acd52bbb2b93@o4509288836694016.ingest.us.sentry.io/4509290148069376"
            options.tracesSampleRate = 1.0
            options.profilesSampleRate = 1.0
            // options.debug = true // Commented out for production
            options.enableAutoSessionTracking = true

            // Adds IP for users.
            // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
            options.sendDefaultPii = true

            // Configure profiling. Visit https://docs.sentry.io/platforms/apple/profiling/ to learn more.
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0 // We recommend adjusting this value in production.
                $0.lifecycle = .trace
            }

            // Uncomment the following lines to add more data to your events
            // options.attachScreenshot = true // This adds a screenshot to the error events
            // options.attachViewHierarchy = true // This adds the view hierarchy to the error events
        }
        // Remove the next line after confirming that your Sentry integration is working.
        SentrySDK.capture(message: "This app uses Sentry! :)")

        // Set navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .dark)
        
        // Set text and icon colors to white for better contrast
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        
        // Add styling for navigation bar buttons
        appearance.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.doneButtonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        
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

