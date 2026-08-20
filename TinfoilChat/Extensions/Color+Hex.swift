//
//  Color+Hex.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

struct ProjectColorRGB: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    init?(identifier: String?) {
        let components: (red: Int, green: Int, blue: Int)
        switch identifier {
        case "maya-blue":
            components = (133, 198, 255)
        case "electric-aqua":
            components = (98, 220, 233)
        case "sandy-brown":
            components = (255, 181, 122)
        case "mauve":
            components = (233, 171, 255)
        case "tuscan-sun":
            components = (245, 203, 88)
        case "light-green":
            components = (138, 223, 141)
        case "baby-pink":
            components = (255, 158, 195)
        default:
            return nil
        }
        red = components.red
        green = components.green
        blue = components.blue
    }
}

extension Color {
    static func projectColor(_ identifier: String?) -> Color {
        guard let rgb = ProjectColorRGB(identifier: identifier) else {
            return .accentColor
        }
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
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
