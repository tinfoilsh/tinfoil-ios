//
//  Theme.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI

extension View {
    func adaptiveNavigationBarAppearance(for colorScheme: ColorScheme, background: Color) -> some View {
        Group {
            if #available(iOS 26, *) {
                self.toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            } else {
                self
                    .toolbarBackground(background, for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            }
        }
        .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}
