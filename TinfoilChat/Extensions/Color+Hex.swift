//
//  Color+Hex.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

extension Color {
    static func projectColor(_ value: String?) -> Color {
        switch value {
        case "maya-blue":
            return Color(red: 133/255, green: 198/255, blue: 255/255)
        case "electric-aqua":
            return Color(red: 98/255, green: 220/255, blue: 233/255)
        case "sandy-brown":
            return Color(red: 255/255, green: 181/255, blue: 122/255)
        case "mauve":
            return Color(red: 233/255, green: 171/255, blue: 255/255)
        case "tuscan-sun":
            return Color(red: 245/255, green: 203/255, blue: 88/255)
        case "light-green":
            return Color(red: 138/255, green: 223/255, blue: 141/255)
        case "baby-pink":
            return Color(red: 255/255, green: 158/255, blue: 195/255)
        default:
            return .accentColor
        }
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
} 
