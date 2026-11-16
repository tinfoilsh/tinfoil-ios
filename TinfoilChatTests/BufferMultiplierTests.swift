import Testing
import Foundation
@testable import TinfoilChat

@Suite("Streaming Buffer Multiplier Tests")
struct BufferMultiplierTests {

    private let windowHeight: CGFloat = 852

    private func makeWrapper() -> ObservableMessageWrapper {
        ObservableMessageWrapper(
            message: Message(role: .assistant, content: "Test"),
            isDarkMode: false,
            isLastMessage: true,
            isLoading: true
        )
    }

    @Test("extendBufferIfNeeded does not extend when content is below threshold")
    func noExtensionBelowThreshold() {
        let wrapper = makeWrapper()
        let bufferHeight = windowHeight * wrapper.bufferMultiplier
        wrapper.actualContentHeight = bufferHeight * 0.5

        let extended = wrapper.extendBufferIfNeeded(windowHeight: windowHeight)

        #expect(extended == false)
        #expect(wrapper.bufferMultiplier == Constants.StreamingBuffer.initialMultiplier)
    }

    @Test("extendBufferIfNeeded extends when content exceeds threshold")
    func extendsAboveThreshold() {
        let wrapper = makeWrapper()
        let bufferHeight = windowHeight * wrapper.bufferMultiplier
        wrapper.actualContentHeight = bufferHeight * 0.95

        let extended = wrapper.extendBufferIfNeeded(windowHeight: windowHeight)

        #expect(extended == true)
        #expect(wrapper.bufferMultiplier == Constants.StreamingBuffer.initialMultiplier + Constants.StreamingBuffer.multiplierIncrement)
    }

    @Test("extendBufferIfNeeded caps multiplier at maximum after repeated calls")
    func multiplierCapsAtMaximum() {
        let wrapper = makeWrapper()

        for _ in 0..<500 {
            wrapper.actualContentHeight = windowHeight * wrapper.bufferMultiplier * 0.95
            wrapper.extendBufferIfNeeded(windowHeight: windowHeight)
        }

        #expect(wrapper.bufferMultiplier == Constants.StreamingBuffer.maxMultiplier)
    }

    @Test("extendBufferIfNeeded does not extend when already at max")
    func noExtensionAtMax() {
        let wrapper = makeWrapper()
        wrapper.bufferMultiplier = Constants.StreamingBuffer.maxMultiplier
        wrapper.actualContentHeight = windowHeight * wrapper.bufferMultiplier * 0.95

        let extended = wrapper.extendBufferIfNeeded(windowHeight: windowHeight)

        #expect(extended == false)
        #expect(wrapper.bufferMultiplier == Constants.StreamingBuffer.maxMultiplier)
    }

    @Test("extendBufferIfNeeded does not extend outside a window")
    func noExtensionWithoutWindow() {
        let wrapper = makeWrapper()
        wrapper.actualContentHeight = windowHeight * wrapper.bufferMultiplier

        let extended = wrapper.extendBufferIfNeeded(windowHeight: 0)

        #expect(extended == false)
        #expect(wrapper.bufferMultiplier == Constants.StreamingBuffer.initialMultiplier)
    }

    @Test("resetBuffer restores initial state")
    func resetRestoresInitialState() {
        let wrapper = makeWrapper()
        wrapper.bufferMultiplier = Constants.StreamingBuffer.maxMultiplier
        wrapper.actualContentHeight = 100_000

        wrapper.resetBuffer()

        #expect(wrapper.bufferMultiplier == Constants.StreamingBuffer.initialMultiplier)
        #expect(wrapper.actualContentHeight == 0)
    }

    @Test("Max possible buffer height stays within safety limit on large screens")
    func maxHeightWithinSafetyLimit() {
        let largeScreenHeight: CGFloat = 1400
        let maxBufferHeight = largeScreenHeight * Constants.StreamingBuffer.maxMultiplier
        let clampedHeight = min(maxBufferHeight, Constants.StreamingBuffer.maxCellHeight)
        #expect(clampedHeight <= Constants.StreamingBuffer.maxCellHeight)
    }
}
