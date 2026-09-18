import SwiftUI

struct BalancedTextLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        return text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let width = Self.balancedWidth(maximumWidth: bounds.width) { width in
            text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        text.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: ProposedViewSize(width: width, height: nil)
        )
    }

    static func balancedWidth(maximumWidth: CGFloat, heightForWidth: (CGFloat) -> CGFloat) -> CGFloat {
        guard maximumWidth.isFinite, maximumWidth > .zero else { return .zero }
        let originalHeight = heightForWidth(maximumWidth)
        guard originalHeight > .zero else { return maximumWidth }

        // Find the narrowest wrapping width that preserves the paragraph's height.
        var lowerBound: CGFloat = .zero
        var upperBound = maximumWidth
        while upperBound - lowerBound > Constants.TextLayout.balanceWidthPrecision {
            let candidate = (lowerBound + upperBound) / 2
            if heightForWidth(candidate) <= originalHeight {
                upperBound = candidate
            } else {
                lowerBound = candidate
            }
        }
        return upperBound
    }
}
