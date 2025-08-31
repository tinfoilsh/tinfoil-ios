//
//  ColorExtension.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

extension Color {
    // App theme colors
    static let backgroundPrimary = Color(hex: "111827")
    static let backgroundSecondary = Color(hex: "1F2937")
    
    // Accent colors
    static let accentPrimary = Color(red: 16/255, green: 185/255, blue: 129/255) // #10B981
    
    // Adaptive accent color for buttons/links that works in both light and dark mode
    static let adaptiveAccent = Color(UIColor { traitCollection in
        if traitCollection.userInterfaceStyle == .dark {
            // White in dark mode for better visibility
            return .white
        } else {
            // Use the green accent in light mode
            return UIColor(red: 16/255, green: 185/255, blue: 129/255, alpha: 1)
        }
    })
} 