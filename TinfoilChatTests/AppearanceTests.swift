import SwiftUI
import Testing
import UIKit
@testable import TinfoilChat

@MainActor
struct AppearanceTests {
    private enum Snapshot {
        static let size = CGSize(width: 390, height: 844)
        static let pixelSize = 1
        static let channelCount = 4
        static let bitsPerComponent = 8
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func startupErrorBackgroundsFollowColorScheme(_ colorScheme: ColorScheme) throws {
        let expected = try backgroundSample(
            colorScheme == .dark ? Color.backgroundPrimary : Color.white,
            colorScheme: colorScheme
        )

        let offline = try backgroundSample(NoInternetView(retryAction: {}), colorScheme: colorScheme)
        let initialization = try backgroundSample(
            InitializationFailedView(errorMessage: "Connection failed", retryAction: {}),
            colorScheme: colorScheme
        )

        #expect(offline == expected)
        #expect(initialization == expected)
    }

    @Test
    func authenticationBorderFollowsAppearanceChanges() throws {
        let textField = AdaptiveBorderTextField()
        let styles: [UIUserInterfaceStyle] = [.light, .dark, .light]

        for style in styles {
            textField.traitOverrides.userInterfaceStyle = style
            textField.updateTraitsIfNeeded()

            #expect(textField.traitCollection.userInterfaceStyle == style)
            let expected = UIColor.systemGray4.resolvedColor(with: textField.traitCollection).cgColor
            let actual = try #require(textField.layer.borderColor)
            #expect(actual == expected)
        }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func authenticationBorderFollowsContrastChanges(_ style: UIUserInterfaceStyle) throws {
        let textField = AdaptiveBorderTextField()
        textField.traitOverrides.userInterfaceStyle = style
        let contrasts: [UIAccessibilityContrast] = [.normal, .high, .normal]

        for contrast in contrasts {
            textField.traitOverrides.accessibilityContrast = contrast
            textField.updateTraitsIfNeeded()

            #expect(textField.traitCollection.userInterfaceStyle == style)
            #expect(textField.traitCollection.accessibilityContrast == contrast)
            let expected = UIColor.systemGray4.resolvedColor(with: textField.traitCollection).cgColor
            let actual = try #require(textField.layer.borderColor)
            #expect(actual == expected)
        }
    }

    private func backgroundSample<Content: View>(
        _ content: Content,
        colorScheme: ColorScheme
    ) throws -> [UInt8] {
        let renderer = ImageRenderer(content: content
            .frame(width: Snapshot.size.width, height: Snapshot.size.height)
            .environment(\.colorScheme, colorScheme))
        let image = try #require(renderer.cgImage)
        var pixel = [UInt8](repeating: 0, count: Snapshot.channelCount)

        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: Snapshot.pixelSize,
                height: Snapshot.pixelSize,
                bitsPerComponent: Snapshot.bitsPerComponent,
                bytesPerRow: Snapshot.channelCount,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(
                origin: .zero,
                size: CGSize(width: image.width, height: image.height)
            ))
        }
        return pixel
    }
}
