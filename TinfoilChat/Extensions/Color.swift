//
//  ColorExtension.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

extension Color {
    // Accent colors
    static let accentPrimary = Color(red: 16/255, green: 185/255, blue: 129/255) // #10B981
    
    // Brand colors
    static let tinfoilDark = Color(hex: "061820")
    static let tinfoilLight = Color(hex: "EEF3F3")
    static let tinfoilAccentDark = Color(hex: "004444")
    static let tinfoilAccentLight = Color(hex: "68C7AC")
    
    // App theme colors
    static let backgroundPrimary = Color.tinfoilDark
    static let backgroundSecondary = Color(hex: "1F2937")
    
    // Additional brand color variations
    static let tealDark = Color(hex: "003333")
    static let mintDark = Color(hex: "5AB39A")
    
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
} 
