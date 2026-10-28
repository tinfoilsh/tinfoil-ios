import Foundation
import Testing
import UIKit
@testable import TinfoilChat

@Suite("Harness uploads")
struct HarnessUploadsTests {
    private static let images = Components.Schemas.FileGroup(accept: [".png"], maxBytes: 10_000_000, imageMaxSide: 100)

    private static func png(side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side / 2))
        }
    }

    @Test func anImageThatFitsUploadsAsItIs() async throws {
        let original = Self.png(side: 50)
        let prepared = try await HarnessUploads.prepare(original, fileName: "a.png", mimeType: "image/png", groups: [Self.images])
        #expect(prepared.data == original)
        #expect(prepared.mimeType == "image/png")
    }

    @Test func anImageLargerThanItsGroupTakesIsScaledDown() async throws {
        let prepared = try await HarnessUploads.prepare(Self.png(side: 400), fileName: "a.png", mimeType: "image/png", groups: [Self.images])
        #expect(prepared.mimeType == "image/jpeg")
        let image = try #require(UIImage(data: prepared.data))
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) == 100)
    }
}
