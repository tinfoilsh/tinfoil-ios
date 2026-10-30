//
//  ColorExtension.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import UIKit

extension Color {
    // Accent colors
    static let accentPrimary = Color(red: 16/255, green: 185/255, blue: 129/255) // #10B981
    
    // Brand colors
    static let tinfoilAccentDark = Color(hex: "004444")
    static let tinfoilAccentBlue = Color(hex: "10347D")
    static let tinfoilAccentBlueLight = Color(hex: "60A5FA")
    
    // App surface colors
    static let backgroundPrimary = Color(hex: "121212")
    static let chatSurfaceDark = Color(hex: "2C2C2E")
    static let chatSurfaceLight = Color(hex: "F2F2F7")
    static let sidebarButtonBackgroundDark = Color(hex: "2C2C2E")
    static let sidebarButtonBackgroundLight = Color.white
    static let cardSurfaceDark = Color(hex: "1C1C1E")
    static let cardSurfaceLight = Color.white
    static let chatBackgroundDark = backgroundPrimary
    static let chatBackgroundLight = Color.white
    static let sidebarBackgroundDark = backgroundPrimary
    static let sidebarBackgroundLight = Color.white
    static let settingsBackgroundDark = backgroundPrimary
    static let settingsBackgroundLight = Color(UIColor.systemGroupedBackground)
    static let sheetBackgroundDark = Color(hex: "161616")
    static let sheetBackgroundLight = Color(UIColor.systemGroupedBackground)
    static let sendButtonBackgroundDark = Color.tinfoilAccentBlue
    static let sendButtonBackgroundLight = Color.tinfoilAccentBlue
    static let sendButtonForegroundDark = Color.white
    static let sendButtonForegroundLight = Color.white

    // Reasoning and messaging surfaces
    static let userMessageBackgroundDark = chatSurfaceDark
    static let userMessageBackgroundLight = chatSurfaceLight
    static let userMessageForegroundDark = Color.white
    static let userMessageForegroundLight = Color.black


    // Adaptive accent color for buttons/links that works in both light and dark mode
    static let adaptiveAccent = Color(UIColor { traitCollection in
        if traitCollection.userInterfaceStyle == .dark {
            // White in dark mode for better visibility
            return .white
        } else {
            // Use the green accent in light mode
            return UIColor(Color.accentPrimary)
        }
    })

    // Convenience helpers for common surfaces
    static func chatSurface(isDarkMode: Bool) -> Color {
        isDarkMode ? chatSurfaceDark : chatSurfaceLight
    }
    
    static func sidebarButtonBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? sidebarButtonBackgroundDark : sidebarButtonBackgroundLight
    }
    
    static func cardSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? cardSurfaceDark : cardSurfaceLight
    }
    
    static func chatBackground(isDarkMode: Bool) -> Color {
        isDarkMode ? chatBackgroundDark : chatBackgroundLight
    }

    static func sidebarBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? sidebarBackgroundDark : sidebarBackgroundLight
    }

    static func settingsBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? settingsBackgroundDark : settingsBackgroundLight
    }

    static func sheetBackground(isDarkMode: Bool) -> Color {
        isDarkMode ? sheetBackgroundDark : sheetBackgroundLight
    }

    static func userMessageBackground(isDarkMode: Bool) -> Color {
        isDarkMode ? userMessageBackgroundDark : userMessageBackgroundLight
    }

    static func userMessageForeground(isDarkMode: Bool) -> Color {
        isDarkMode ? userMessageForegroundDark : userMessageForegroundLight
    }
}
