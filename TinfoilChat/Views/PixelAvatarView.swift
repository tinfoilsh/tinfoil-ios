//
//  PixelAvatarView.swift
//  TinfoilChat
//
//  Deterministic pixel avatar matching the boring-avatars "pixel" variant
//  used on the landing site for users without a profile image.

import SwiftUI

struct PixelAvatarView: View {
    let name: String
    let size: CGFloat

    private let baseSize: CGFloat = 80
    private let baseCellSize: CGFloat = 10
    private let colors: [Color] = [
        Color(hex: Constants.Avatar.primaryColorHex),
        Color(hex: Constants.Avatar.secondaryColorHex)
    ]
    private let pixelPositions: [(x: CGFloat, y: CGFloat)] = [
        (0, 0), (20, 0), (40, 0), (60, 0), (10, 0), (30, 0), (50, 0), (70, 0),
        (0, 10), (0, 20), (0, 30), (0, 40), (0, 50), (0, 60), (0, 70),
        (20, 10), (20, 20), (20, 30), (20, 40), (20, 50), (20, 60), (20, 70),
        (40, 10), (40, 20), (40, 30), (40, 40), (40, 50), (40, 60), (40, 70),
        (60, 10), (60, 20), (60, 30), (60, 40), (60, 50), (60, 60), (60, 70),
        (10, 10), (10, 20), (10, 30), (10, 40), (10, 50), (10, 60), (10, 70),
        (30, 10), (30, 20), (30, 30), (30, 40), (30, 50), (30, 60), (30, 70),
        (50, 10), (50, 20), (50, 30), (50, 40), (50, 50), (50, 60), (50, 70),
        (70, 10), (70, 20), (70, 30), (70, 40), (70, 50), (70, 60), (70, 70)
    ]

    var body: some View {
        let pixelColors = generateColors(name: name)

        Canvas { context, canvasSize in
            let scaleX = canvasSize.width / baseSize
            let scaleY = canvasSize.height / baseSize
            let cellWidth = baseCellSize * scaleX
            let cellHeight = baseCellSize * scaleY

            for (index, position) in pixelPositions.enumerated() {
                let rect = CGRect(
                    x: position.x * scaleX,
                    y: position.y * scaleY,
                    width: cellWidth,
                    height: cellHeight
                )
                context.fill(
                    Path(rect),
                    with: .color(pixelColors[index])
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func generateColors(name: String) -> [Color] {
        let hash = hashCode(name)
        let range = colors.count
        return (0..<pixelPositions.count).map { i in
            colors[(hash % (i + 1)) % range]
        }
    }

    private func hashCode(_ name: String) -> Int {
        var hash: Int32 = 0
        for char in name.unicodeScalars {
            hash = ((hash &<< 5) &- hash) &+ Int32(char.value)
        }
        return Int(hash.magnitude)
    }
}
