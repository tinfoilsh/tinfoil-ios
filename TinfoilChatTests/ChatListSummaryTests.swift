import Foundation
import Testing
@testable import TinfoilChat

struct ChatListSummaryTests {
    @Test
    func convertsChatSidebarFields() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        var chat = Chat(
            id: "local-chat",
            title: "Local notes",
            createdAt: createdAt,
            modelType: ChatSearchServiceTests.testModel,
            updatedAt: updatedAt,
            isLocalOnly: true,
            projectId: "project-1"
        )
        chat.decryptionFailed = true
        chat.isTemporary = true

        let summary = ChatListSummary(from: chat)

        #expect(summary.id == chat.id)
        #expect(summary.title == chat.title)
        #expect(summary.createdAt == createdAt)
        #expect(summary.updatedAt == updatedAt)
        #expect(summary.projectId == "project-1")
        #expect(summary.isLocalOnly)
        #expect(summary.decryptionFailed)
        #expect(!summary.isBlankChat)
        #expect(summary.isTemporary)
    }

    @Test
    func convertsIndexEntrySidebarFieldsWithoutChangingSchema() {
        let createdAt = Date(timeIntervalSince1970: 300)
        let updatedAt = Date(timeIntervalSince1970: 400)
        var chat = Chat(
            id: "indexed-chat",
            title: "Indexed notes",
            createdAt: createdAt,
            modelType: ChatSearchServiceTests.testModel,
            updatedAt: updatedAt,
            isLocalOnly: true,
            projectId: "project-2"
        )
        chat.decryptionFailed = true
        let entry = ChatIndexEntry(from: chat)

        let summary = ChatListSummary(from: entry)

        #expect(summary.id == entry.id)
        #expect(summary.title == entry.title)
        #expect(summary.createdAt == createdAt)
        #expect(summary.updatedAt == updatedAt)
        #expect(summary.projectId == "project-2")
        #expect(summary.isLocalOnly)
        #expect(summary.decryptionFailed)
        #expect(!summary.isBlankChat)
        #expect(!summary.isTemporary)
    }

    @Test
    func preservesBlankStateFromIndexMetadata() {
        let chat = ChatSearchServiceTests.makeChat(id: "blank", title: "New Chat")
        let entry = ChatIndexEntry(from: chat)

        #expect(ChatListSummary(from: chat).isBlankChat)
        #expect(ChatListSummary(from: entry).isBlankChat)
    }
}
