import Foundation
import Testing
@testable import TinfoilChat

struct ChatDraftRefreshTests {
    @Test(arguments: [false, true])
    func repeatedRefreshesPreserveRecordingAndTranscriptionIdentity(isLocalOnly: Bool) throws {
        var draft = Chat(
            modelType: ChatSearchServiceTests.testModel,
            userId: "user",
            isLocalOnly: isLocalOnly
        )
        let recordingChatId = draft.id
        let createdAt = draft.createdAt
        var transcriptionFence = ChatSelectionFence()
        let generation = transcriptionFence.begin(id: draft.id)

        for _ in 0..<3 {
            draft = try #require(draft.blankDraftForListRefresh(
                isLocalOnly: isLocalOnly,
                userId: "user"
            ))
            #expect(draft.id == recordingChatId)
            #expect(draft.createdAt == createdAt)
            #expect(transcriptionFence.accepts(id: draft.id, generation: generation))
        }
    }

    @Test(arguments: [false, true])
    func preservesDraftSettingsAndTemporaryState(isTemporary: Bool) throws {
        var draft = Chat(
            title: "Draft",
            modelType: ChatSearchServiceTests.testModel,
            language: "en",
            userId: "user",
            isLocalOnly: isTemporary,
            projectId: isTemporary ? nil : "project",
            promptPresetId: "user:preset",
            webSearchEnabled: false
        )
        draft.isTemporary = isTemporary

        let refreshed = try #require(draft.blankDraftForListRefresh(
            isLocalOnly: draft.isLocalOnly,
            userId: "user"
        ))

        #expect(refreshed.id == draft.id)
        #expect(refreshed.title == draft.title)
        #expect(refreshed.modelType == draft.modelType)
        #expect(refreshed.language == draft.language)
        #expect(refreshed.updatedAt == draft.updatedAt)
        #expect(refreshed.projectId == draft.projectId)
        #expect(refreshed.promptPresetId == draft.promptPresetId)
        #expect(refreshed.webSearchEnabled == draft.webSearchEnabled)
        #expect(refreshed.isTemporary == draft.isTemporary)
    }

    @Test
    func assignsTheSignedInAccountWithoutReplacingTheLaunchDraft() throws {
        let draft = Chat(modelType: ChatSearchServiceTests.testModel)

        let refreshed = try #require(draft.blankDraftForListRefresh(
            isLocalOnly: false,
            userId: "user"
        ))

        #expect(refreshed.id == draft.id)
        #expect(refreshed.userId == "user")
        #expect(draft.userId == nil)
    }

    @Test(arguments: [false, true])
    func doesNotReuseADraftFromTheOtherStorage(isLocalOnly: Bool) {
        let draft = Chat(
            modelType: ChatSearchServiceTests.testModel,
            userId: "user",
            isLocalOnly: isLocalOnly
        )

        #expect(draft.blankDraftForListRefresh(isLocalOnly: !isLocalOnly, userId: "user") == nil)
    }

    @Test
    func doesNotReuseAnotherAccountsDraft() {
        let draft = Chat(modelType: ChatSearchServiceTests.testModel, userId: "original")

        #expect(draft.blankDraftForListRefresh(isLocalOnly: false, userId: "other") == nil)
        #expect(draft.blankDraftForListRefresh(isLocalOnly: false, userId: nil) == nil)
    }

    @Test
    func doesNotReuseConversationsOrDecryptionFailuresAsBlankDrafts() {
        let conversation = Chat(
            messages: [Message(role: .user, content: "Hello")],
            modelType: ChatSearchServiceTests.testModel,
            userId: "user"
        )
        let failedChat = Chat(
            modelType: ChatSearchServiceTests.testModel,
            userId: "user",
            decryptionFailed: true
        )

        #expect(conversation.blankDraftForListRefresh(isLocalOnly: false, userId: "user") == nil)
        #expect(failedChat.blankDraftForListRefresh(isLocalOnly: false, userId: "user") == nil)
    }
}
