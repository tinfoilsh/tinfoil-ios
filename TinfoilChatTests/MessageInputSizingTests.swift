import SwiftUI
import Testing
@testable import TinfoilChat

@MainActor
struct MessageInputSizingTests {
    private static let phoneWidth: CGFloat = 320
    private static let minimumHeight: CGFloat = 72
    private static let maximumHeight: CGFloat = 180
    private static let paragraph = "This is a transcribed voice message with enough words to wrap across several lines in the message input without requiring the user to open the keyboard or type anything. "

    @Test
    func initialTranscriptionExpandsWithoutKeyboardInput() {
        let host = UIHostingController(rootView: editor(text: String(repeating: Self.paragraph, count: 3)))

        let size = host.sizeThatFits(in: CGSize(width: Self.phoneWidth, height: .greatestFiniteMagnitude))

        #expect(size.width == Self.phoneWidth)
        #expect(size.height == Self.maximumHeight)
    }

    @Test
    func programmaticTranscriptionExpandsAndClearingShrinksTheEditor() {
        let host = UIHostingController(rootView: editor(text: "Existing draft"))
        let proposal = CGSize(width: Self.phoneWidth, height: .greatestFiniteMagnitude)
        #expect(host.sizeThatFits(in: proposal).height == Self.minimumHeight)

        host.rootView = editor(text: "Existing draft " + String(repeating: Self.paragraph, count: 3))
        #expect(host.sizeThatFits(in: proposal).height == Self.maximumHeight)

        host.rootView = editor(text: "")
        #expect(host.sizeThatFits(in: proposal).height == Self.minimumHeight)
    }

    @Test
    func layoutUsesTheProposedWidthRatherThanThePreviousFrame() {
        let host = UIHostingController(rootView: editor(text: Self.paragraph))
        let wideProposal = CGSize(width: 600, height: .greatestFiniteMagnitude)
        let narrowProposal = CGSize(width: 180, height: .greatestFiniteMagnitude)

        let wideSize = host.sizeThatFits(in: wideProposal)
        let narrowSize = host.sizeThatFits(in: narrowProposal)
        let wideAgain = host.sizeThatFits(in: wideProposal)

        #expect(narrowSize.height > wideSize.height)
        #expect(narrowSize.height <= Self.maximumHeight)
        #expect(wideAgain == wideSize)
    }

    @Test
    func veryLongTranscriptionStaysWithinTheScrollableHeightLimit() {
        let host = UIHostingController(rootView: editor(text: String(repeating: Self.paragraph, count: 100)))

        let size = host.sizeThatFits(in: CGSize(width: Self.phoneWidth, height: .greatestFiniteMagnitude))

        #expect(size.height == Self.maximumHeight)
    }

    private func editor(text: String) -> CustomTextEditor {
        CustomTextEditor(
            text: .constant(text),
            placeholderText: "Message",
            shouldFocusInput: false,
            onFocusHandled: {},
            onSendMessage: { _ in false }
        )
    }
}
