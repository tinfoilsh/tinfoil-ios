import SwiftUI
import Testing
import UIKit
@testable import TinfoilChat

@Suite("Project Color Tests")
struct ProjectColorTests {
    @Test("Web project colors resolve", arguments: [
        ("maya-blue", 133, 198, 255),
        ("electric-aqua", 98, 220, 233),
        ("sandy-brown", 255, 181, 122),
        ("mauve", 233, 171, 255),
        ("tuscan-sun", 245, 203, 88),
        ("light-green", 138, 223, 141),
        ("baby-pink", 255, 158, 195),
    ])
    func webProjectColorsResolve(id: String, red: Int, green: Int, blue: Int) {
        let components = rgbaComponents(of: Color.projectColor(id))

        #expect(abs(components.red - Double(red) / 255) < 0.0001)
        #expect(abs(components.green - Double(green) / 255) < 0.0001)
        #expect(abs(components.blue - Double(blue) / 255) < 0.0001)
        #expect(abs(components.alpha - 1) < 0.0001)
    }

    @Test("Missing project colors use the accent")
    func missingProjectColorsUseAccent() {
        #expect(Color.projectColor(nil) == Color.accentColor)
    }

    @Test("Invalid project colors use the accent")
    func invalidProjectColorsUseAccent() {
        #expect(Color.projectColor("#85C6FF") == Color.accentColor)
        #expect(Color.projectColor("unknown") == Color.accentColor)
    }

    @Test("Project rows use the project folder icon")
    func projectRowsUseProjectFolderIcon() throws {
        let source = try sourceFile("TinfoilChat/Views/ChatSidebar.swift")

        #expect(source.contains("ProjectFolderIcon(color: project.color)"))
        #expect(source.contains("ProjectFolderIcon(color: projectColor, size: 18)"))
        #expect(source.contains("ProjectFolderIcon(color: project.color, size: 22)"))
    }

    private func rgbaComponents(of color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var red = CGFloat.zero
        var green = CGFloat.zero
        var blue = CGFloat.zero
        var alpha = CGFloat.zero
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
