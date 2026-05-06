//
//  GhostIcon.swift
//  TinfoilChat
//
//  SwiftUI rendering of the "ghost" glyph used by the webapp's temporary
//  chat button (`SlGhost` from simple-line-icons / react-icons). Drawn
//  directly with `Shape` so it scales cleanly and matches the look of the
//  web button.
//

import SwiftUI

/// The ghost silhouette: rounded dome on top, three scalloped humps along
/// the bottom edge, with two circular eyes punched out of the body.
struct GhostIcon: View {
    enum Style {
        case outline
        case filled
    }

    var size: CGFloat = 18
    var color: Color = .primary
    var style: Style = .outline

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let body = bodyPath(in: rect)
            let eyes = eyesPath(in: rect)

            switch style {
            case .filled:
                let punched = body.subtracting(eyes)
                context.fill(punched, with: .color(color))
            case .outline:
                let lineWidth = max(1.4, canvasSize.width * 0.085)
                context.stroke(
                    body,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
                context.fill(eyes, with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func bodyPath(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04)
        let topRadius = inset.width / 2
        let bottomY = inset.maxY
        let scallopHeight = inset.height * 0.16
        let humpCount = 3
        let humpWidth = inset.width / CGFloat(humpCount)

        var p = Path()
        // Start at the right edge, just below the top arc.
        p.move(to: CGPoint(x: inset.maxX, y: inset.minY + topRadius))
        // Down the right side.
        p.addLine(to: CGPoint(x: inset.maxX, y: bottomY))
        // Scalloped bottom right-to-left.
        for i in 0..<humpCount {
            let endX = inset.maxX - CGFloat(i + 1) * humpWidth
            let controlX = endX + humpWidth / 2
            p.addQuadCurve(
                to: CGPoint(x: endX, y: bottomY),
                control: CGPoint(x: controlX, y: bottomY - scallopHeight)
            )
        }
        // Up the left side.
        p.addLine(to: CGPoint(x: inset.minX, y: inset.minY + topRadius))
        // Top arc back to start.
        p.addArc(
            center: CGPoint(x: inset.midX, y: inset.minY + topRadius),
            radius: topRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }

    private func eyesPath(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04)
        let eyeSize = inset.width * 0.16
        let y = inset.minY + inset.height * 0.42 - eyeSize / 2
        let leftX = inset.minX + inset.width * 0.32 - eyeSize / 2
        let rightX = inset.minX + inset.width * 0.68 - eyeSize / 2
        var p = Path()
        p.addEllipse(in: CGRect(x: leftX, y: y, width: eyeSize, height: eyeSize))
        p.addEllipse(in: CGRect(x: rightX, y: y, width: eyeSize, height: eyeSize))
        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        GhostIcon(size: 32, color: .primary, style: .outline)
        GhostIcon(size: 32, color: .accentColor, style: .filled)
    }
    .padding()
}
