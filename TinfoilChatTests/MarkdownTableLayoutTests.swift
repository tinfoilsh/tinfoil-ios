import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import TinfoilChat

@Suite("Markdown Table Layout Tests")
struct MarkdownTableLayoutTests {
    @Test("Caps a wide column at half the available table width")
    func capsWideColumnRelativeToAvailableWidth() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 500,
            availableWidth: 320
        )

        #expect(width == 160)
    }

    @Test("Preserves intrinsic width below the responsive cap")
    func preservesNarrowColumnWidth() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 120,
            availableWidth: 600
        )

        #expect(width == 120)
    }

    @Test("Preserves intrinsic width before container measurement")
    func preservesIntrinsicWidthWithoutAvailableWidth() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 420,
            availableWidth: nil
        )

        #expect(width == 420)
    }
}

@MainActor
@Suite("Markdown Table Grid Tests")
struct MarkdownTableGridTests {
    nonisolated private static let textSizes: [DynamicTypeSize] = [.large, .accessibility3]
    /// Hosted sizes are rounded to the display scale, so the grid and the sum
    /// of separately hosted cells can differ by a fraction of a point.
    private static let pixelRoundingTolerance: CGFloat = 1

    private func fittingSize(
        of view: some View,
        textSize: DynamicTypeSize,
        width: CGFloat = .greatestFiniteMagnitude
    ) -> CGSize {
        UIHostingController(rootView: view
            .font(.body)
            .environment(\.dynamicTypeSize, textSize))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @Test(
        "Sizes each column to its widest rendered cell without wrapping",
        arguments: MarkdownTableGridTests.textSizes
    )
    func sizesColumnsToRenderedCells(textSize: DynamicTypeSize) {
        let cells = ["Per month (730 hr)", "Share", "$41,459", "11.5%"]
        let cellSizes = cells.map { fittingSize(of: Text($0), textSize: textSize) }

        let grid = fittingSize(
            of: MarkdownTableGrid(columnCount: 2, availableWidth: nil) {
                ForEach(cells, id: \.self) { Text($0) }
            },
            textSize: textSize
        )

        let expectedWidth = max(cellSizes[0].width, cellSizes[2].width)
            + max(cellSizes[1].width, cellSizes[3].width)
        let singleLineHeight = max(cellSizes[0].height, cellSizes[1].height)
            + max(cellSizes[2].height, cellSizes[3].height)
        #expect(abs(grid.width - expectedWidth) < Self.pixelRoundingTolerance)
        #expect(abs(grid.height - singleLineHeight) < Self.pixelRoundingTolerance)
    }

    @Test("Wraps a cell wider than the column cap onto more lines")
    func wrapsCellsWiderThanTheCap() {
        let text = "A cell long enough that it cannot fit on one line in half of a narrow table"
        let availableWidth: CGFloat = 240
        let cap = MarkdownTableLayout.columnWidth(
            intrinsicWidth: .greatestFiniteMagnitude,
            availableWidth: availableWidth
        )
        let singleLine = fittingSize(of: Text(text), textSize: .large)
        let wrapped = fittingSize(of: Text(text), textSize: .large, width: cap)

        let grid = fittingSize(
            of: MarkdownTableGrid(columnCount: 1, availableWidth: availableWidth) {
                Text(text)
            },
            textSize: .large
        )

        #expect(abs(grid.width - cap) < Self.pixelRoundingTolerance)
        #expect(abs(grid.height - wrapped.height) < Self.pixelRoundingTolerance)
        #expect(grid.height > singleLine.height)
    }
}
