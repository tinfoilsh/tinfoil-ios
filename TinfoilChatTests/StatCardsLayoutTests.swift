import CoreGraphics
import Testing
@testable import TinfoilChat

@Suite("Stat Cards Layout Tests")
struct StatCardsLayoutTests {
    @Test("Uses the tallest content height for every card")
    func usesTallestContentHeight() {
        var height = StatCardHeightPreferenceKey.defaultValue

        StatCardHeightPreferenceKey.reduce(value: &height) { 72 }
        StatCardHeightPreferenceKey.reduce(value: &height) { 128 }
        StatCardHeightPreferenceKey.reduce(value: &height) { 96 }

        #expect(height == 128)
    }
}
