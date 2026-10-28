import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
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

    /// The groups the harness offers: text, and the image types it decodes.
    private static let harnessGroups = [
        Components.Schemas.FileGroup(accept: [".txt", ".md"], maxBytes: 10_000),
        Components.Schemas.FileGroup(accept: [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tiff", ".tif"], maxBytes: 10_000_000, imageMaxSide: 100),
    ]

    private static func encoded(_ type: UTType, side: CGFloat) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        }.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aPhotoOfATypeTheHarnessCannotDecodeUploadsAsAJPEG() async throws {
        let heic = try Self.encoded(.heic, side: 50)
        #expect(HarnessUploads.imageType(of: heic) == .heic)
        // The photo picker names every photo a JPEG, and another app may
        // share one under any name.
        for (name, uploaded) in [("IMG_0001.HEIC", "IMG_0001.jpg"), ("Photo.jpg", "Photo.jpg"), ("shared image", "shared image.jpg")] {
            let prepared = try await HarnessUploads.prepare(heic, fileName: name, mimeType: "image/heic", groups: Self.harnessGroups)
            #expect(prepared.fileName == uploaded)
            #expect(prepared.mimeType == "image/jpeg")
            #expect(HarnessUploads.imageType(of: prepared.data) == .jpeg)
            let image = try #require(UIImage(data: prepared.data))
            #expect(image.size == CGSize(width: 50, height: 50))
        }
    }

    @Test func anImageTheHarnessDecodesKeepsItsBytesUnderANameForItsType() async throws {
        let png = Self.png(side: 50)
        let misnamed = try await HarnessUploads.prepare(png, fileName: "Photo.jpg", mimeType: "image/jpeg", groups: Self.harnessGroups)
        #expect(misnamed.data == png)
        #expect(misnamed.fileName == "Photo.jpg")
        #expect(misnamed.mimeType == "image/png")
        let unnamed = try await HarnessUploads.prepare(png, fileName: "image", mimeType: "application/octet-stream", groups: Self.harnessGroups)
        #expect(unnamed.data == png)
        #expect(unnamed.fileName == "image.png")
    }

    @Test func aFileThatIsNoImageUploadsAsItIs() async throws {
        let notes = Data("# Notes".utf8)
        let prepared = try await HarnessUploads.prepare(notes, fileName: "notes.md", mimeType: "text/markdown", groups: Self.harnessGroups)
        #expect(prepared.data == notes)
        #expect(prepared.fileName == "notes.md")
        #expect(prepared.mimeType == "text/markdown")
    }
}
