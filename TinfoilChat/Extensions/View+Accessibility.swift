//
//  View+Accessibility.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

extension View {
    /// Expands an interactive element's hit area to at least `minSize` points
    /// in each dimension, matching the 44pt minimum touch target recommended
    /// by Apple's Human Interface Guidelines. The contained icon keeps its own
    /// size; only the tappable region grows.
    func accessibleHitTarget(minSize: CGFloat = 44) -> some View {
        frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}
