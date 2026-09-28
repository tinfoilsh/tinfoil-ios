//
//  UserMessagePresentationTests.swift
//  TinfoilChatTests
//

import Foundation
import Testing
@testable import TinfoilChat

struct UserMessagePresentationTests {
    @Test func longPreviewIsBoundedAndClearlyTruncated() {
        let content = String(repeating: "a", count: UserMessagePresentation.previewCharacterLimit + 100)
        let preview = UserMessagePresentation.preview(for: content)

        #expect(preview.hasSuffix("…"))
        #expect(preview.count == UserMessagePresentation.previewCharacterLimit + 1)
        #expect(!preview.contains("Long Message"))
    }

    @Test func previewTrimsWhitespaceWithoutTruncatingShortMessages() {
        #expect(UserMessagePresentation.preview(for: "  **Hello** world\n") == "**Hello** world")
    }

    @Test func initialSelectionChoosesFirstWordAfterWhitespace() throws {
        let content = " \n  Select this text"
        let range = try #require(UserMessagePresentation.firstSelectableRange(in: content))

        #expect((content as NSString).substring(with: range) == "Select")
    }

    @Test func initialSelectionHandlesUnicodeAndEmptyContent() throws {
        let content = "  👋🏽 hello"
        let range = try #require(UserMessagePresentation.firstSelectableRange(in: content))

        #expect((content as NSString).substring(with: range) == "👋🏽")
        #expect(UserMessagePresentation.firstSelectableRange(in: " \n\t") == nil)
    }

    @Test func onlyLongUserMessagesUseCollapsedPresentation() {
        let threshold = Message.longMessageAttachmentThreshold

        #expect(Message(role: .user, content: String(repeating: "x", count: threshold)).shouldDisplayAsAttachment)
        #expect(!Message(role: .user, content: String(repeating: "x", count: threshold - 1)).shouldDisplayAsAttachment)
        #expect(!Message(role: .assistant, content: String(repeating: "x", count: threshold)).shouldDisplayAsAttachment)
    }
}
