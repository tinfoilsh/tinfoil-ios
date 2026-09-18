import SwiftUI
import Testing
@testable import TinfoilChat

@MainActor
struct BalancedTextLayoutTests {
    nonisolated private static let widths: [CGFloat] = [240, 390]
    nonisolated private static let textSizes: [DynamicTypeSize] = [.large, .accessibility3]

    private var paragraph: Text {
        Text("Tinfoil Chat runs every conversation inside secure enclaves, giving you access to powerful AI models with verifiable conversation privacy.\n\n\(Text("Even Tinfoil cannot access your conversations.").fontWeight(.semibold))")
    }

    @Test(arguments: BalancedTextLayoutTests.widths, BalancedTextLayoutTests.textSizes)
    func narrowsWrappingWithoutAddingLines(width: CGFloat, textSize: DynamicTypeSize) {
        let host = UIHostingController(rootView: paragraph
            .font(.body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, textSize))
        let heightForWidth: (CGFloat) -> CGFloat = { width in
            host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let originalHeight = heightForWidth(width)

        let balancedWidth = BalancedTextLayout.balancedWidth(maximumWidth: width, heightForWidth: heightForWidth)

        #expect(balancedWidth > .zero)
        #expect(balancedWidth <= width)
        #expect(heightForWidth(balancedWidth) == originalHeight)
        let narrowerWidth = max(.zero, balancedWidth - Constants.TextLayout.balanceWidthPrecision * 2)
        #expect(heightForWidth(narrowerWidth) > originalHeight)
    }

    @Test(arguments: BalancedTextLayoutTests.widths, BalancedTextLayoutTests.textSizes)
    func preservesTheParagraphsLayoutSize(width: CGFloat, textSize: DynamicTypeSize) {
        let plain = UIHostingController(rootView: paragraph
            .font(.body)
            .environment(\.dynamicTypeSize, textSize))
        let balanced = UIHostingController(rootView: BalancedTextLayout {
            paragraph
        }
        .font(.body)
        .environment(\.dynamicTypeSize, textSize))
        let proposal = CGSize(width: width, height: .greatestFiniteMagnitude)

        #expect(balanced.sizeThatFits(in: proposal) == plain.sizeThatFits(in: proposal))
    }
}
