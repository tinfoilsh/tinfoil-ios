//
//  GridTexture.swift
//  TinfoilChat
//

import SwiftUI

struct GridTexture: View {
    let isDarkMode: Bool

    var body: some View {
        Canvas { context, size in
            let spacing = Constants.UI.TextureGrid.spacing
            let lineColor = (isDarkMode ? Color.white : Color.black)
                .opacity(Constants.UI.TextureGrid.opacity)
            var path = Path()

            var x = (size.width / 2 - spacing / 2)
                .truncatingRemainder(dividingBy: spacing)
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }

            var y = (size.height / 2 - spacing / 2)
                .truncatingRemainder(dividingBy: spacing)
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }

            context.stroke(
                path,
                with: .color(lineColor),
                lineWidth: Constants.UI.TextureGrid.lineWidth
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
