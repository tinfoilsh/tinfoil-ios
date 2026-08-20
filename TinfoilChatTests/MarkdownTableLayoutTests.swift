import CoreGraphics
import Testing
@testable import TinfoilChat

@Suite("Markdown Table Layout Tests")
struct MarkdownTableLayoutTests {
    @Test("Caps a wide column at half the available table width")
    func capsWideColumnRelativeToAvailableWidth() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 500,
            availableWidth: 320,
            columnCount: 1
        )

        #expect(width == 160)
    }

    @Test("Preserves intrinsic width below the responsive cap")
    func preservesNarrowColumnWidth() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 120,
            availableWidth: 600,
            columnCount: 3
        )

        #expect(width == 120)
    }

    @Test("Preserves intrinsic width before container measurement")
    func preservesIntrinsicWidthWithoutAvailableWidth() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 420,
            availableWidth: nil,
            columnCount: 2
        )

        #expect(width == 420)
    }

    @Test("Leaves room for column dividers at the width cap")
    func accountsForColumnDividers() {
        let width = MarkdownTableLayout.columnWidth(
            intrinsicWidth: 500,
            availableWidth: 320,
            columnCount: 2
        )

        #expect(width == 159.5)
    }
}
