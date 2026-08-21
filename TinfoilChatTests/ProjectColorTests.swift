import SwiftUI
import Testing
import UIKit
@testable import TinfoilChat

@Suite("Project Color Tests")
struct ProjectColorTests {
    @Test("Exact web project color identifiers parse", arguments: [
        ("maya-blue", 133, 198, 255),
        ("electric-aqua", 98, 220, 233),
        ("sandy-brown", 255, 181, 122),
        ("mauve", 233, 171, 255),
        ("tuscan-sun", 245, 203, 88),
        ("light-green", 138, 223, 141),
        ("baby-pink", 255, 158, 195),
    ])
    func exactWebProjectColorIdentifiersParse(id: String, red: Int, green: Int, blue: Int) {
        let parsed = ProjectColorRGB(identifier: id)

        #expect(parsed?.red == red)
        #expect(parsed?.green == green)
        #expect(parsed?.blue == blue)
    }

    @Test("Non-web project color identifiers do not parse")
    func nonWebProjectColorIdentifiersDoNotParse() {
        #expect(ProjectColorRGB(identifier: nil) == nil)
        #expect(ProjectColorRGB(identifier: "Maya-Blue") == nil)
        #expect(ProjectColorRGB(identifier: " maya-blue") == nil)
        #expect(ProjectColorRGB(identifier: "#85C6FF") == nil)
        #expect(ProjectColorRGB(identifier: "unknown") == nil)
    }

    @Test("Web project colors render with web RGB values", arguments: [
        ("maya-blue", 133, 198, 255),
        ("electric-aqua", 98, 220, 233),
        ("sandy-brown", 255, 181, 122),
        ("mauve", 233, 171, 255),
        ("tuscan-sun", 245, 203, 88),
        ("light-green", 138, 223, 141),
        ("baby-pink", 255, 158, 195),
    ])
    func webProjectColorsRender(id: String, red: Int, green: Int, blue: Int) {
        let components = rgbaComponents(of: Color.projectColor(id))

        #expect(abs(components.red - Double(red) / 255) < 0.0001)
        #expect(abs(components.green - Double(green) / 255) < 0.0001)
        #expect(abs(components.blue - Double(blue) / 255) < 0.0001)
        #expect(abs(components.alpha - 1) < 0.0001)
    }

    @Test("Missing and invalid project colors use the accent")
    func missingAndInvalidProjectColorsUseAccent() {
        #expect(Color.projectColor(nil) == Color.accentColor)
        #expect(Color.projectColor("unknown") == Color.accentColor)
    }

    private func rgbaComponents(of color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var red = CGFloat.zero
        var green = CGFloat.zero
        var blue = CGFloat.zero
        var alpha = CGFloat.zero
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }
}
