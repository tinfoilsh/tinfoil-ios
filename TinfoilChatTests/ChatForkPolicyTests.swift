//
//  ChatForkPolicyTests.swift
//  TinfoilChatTests
//

import Foundation
import Testing
@testable import TinfoilChat

struct ChatForkPolicyTests {
    private static func makeChat(
        userId: String? = "user-1",
        isLocalOnly: Bool = false,
        locallyModified: Bool = false,
        decryptionFailed: Bool = false,
        messages: [Message] = [Message(role: .user, content: "hi")]
    ) -> Chat {
        Chat(
            id: "chat-source",
            title: "Trip planning",
            messages: messages,
            modelType: ChatForkTests.model,
            userId: userId,
            syncVersion: 3,
            locallyModified: locallyModified,
            decryptionFailed: decryptionFailed,
            isLocalOnly: isLocalOnly
        )
    }

    @Test func cleanSyncedSourceIsReadyAndDirtySourceNeedsFlush() {
        #expect(
            ChatForkPolicy.sourceReadiness(Self.makeChat(), activeUserId: "user-1") == .ready
        )
        #expect(
            ChatForkPolicy.sourceReadiness(
                Self.makeChat(locallyModified: true),
                activeUserId: "user-1"
            ) == .needsFlush
        )
    }

    @Test func ineligibleSourcesAreRejectedBeforeTheEnclaveIsAsked() {
        #expect(
            ChatForkPolicy.sourceReadiness(nil, activeUserId: "user-1") == .ineligible(.notFound)
        )
        #expect(
            ChatForkPolicy.sourceReadiness(
                Self.makeChat(userId: "user-2"),
                activeUserId: "user-1"
            ) == .ineligible(.otherAccount)
        )
        #expect(
            ChatForkPolicy.sourceReadiness(
                Self.makeChat(isLocalOnly: true),
                activeUserId: "user-1"
            ) == .ineligible(.localOnly)
        )
        #expect(
            ChatForkPolicy.sourceReadiness(
                Self.makeChat(decryptionFailed: true),
                activeUserId: "user-1"
            ) == .ineligible(.unreadable)
        )
        #expect(
            ChatForkPolicy.sourceReadiness(
                Self.makeChat(messages: []),
                activeUserId: "user-1"
            ) == .ineligible(.empty)
        )
    }

    @Test func aRowWithoutAnOwnerBelongsToTheActiveAccount() {
        #expect(
            ChatForkPolicy.sourceReadiness(Self.makeChat(userId: nil), activeUserId: "user-1") == .ready
        )
    }

    @Test func flushIsOnlyCompleteWhenTheRowIsClean() {
        #expect(ChatForkPolicy.isFlushed(Self.makeChat()))
        #expect(!ChatForkPolicy.isFlushed(Self.makeChat(locallyModified: true)))
        #expect(!ChatForkPolicy.isFlushed(nil))
    }

    @Test func messageCountMustSelectANonEmptyPrefix() {
        #expect(ChatForkPolicy.isValidMessageCount(1, sourceMessageCount: 3))
        #expect(ChatForkPolicy.isValidMessageCount(3, sourceMessageCount: 3))
        #expect(!ChatForkPolicy.isValidMessageCount(0, sourceMessageCount: 3))
        #expect(!ChatForkPolicy.isValidMessageCount(4, sourceMessageCount: 3))
    }

    @Test func localForkPinsTheSourceModelAndStartsSynced() {
        let otherModel = ModelType(
            from: AppModelConfig(
                modelName: "other-model",
                image: "other.png",
                name: "Other",
                nameShort: "Other",
                description: "",
                details: "",
                parameters: "",
                type: "chat",
                chat: true,
                paid: false,
                multimodal: false,
                toolCalling: nil,
                chatConfig: ChatModelConfig(
                    contextWindowTokens: 8_000,
                    attributes: nil,
                    descriptionShort: nil,
                    reasoningConfig: nil
                )
            )
        )
        var pulled = Self.makeChat(locallyModified: true)
        pulled.modelType = otherModel
        pulled.pendingSave = true

        let fork = ChatForkPolicy.localFork(from: pulled, sourceModel: ChatForkTests.model)

        #expect(fork.modelType.id == ChatForkTests.model.id)
        #expect(fork.locallyModified == false)
        #expect(fork.syncedAt != nil)
        #expect(fork.pendingSave == false)
        #expect(fork.syncVersion == 3)
        #expect(fork.messages == pulled.messages)
    }
}
