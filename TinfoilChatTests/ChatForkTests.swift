//
//  ChatForkTests.swift
//  TinfoilChatTests
//

import Foundation
import Testing
@testable import TinfoilChat

struct ChatForkTests {
    nonisolated static let model = ModelType(
        from: AppModelConfig(
            modelName: "gpt-oss-120b",
            image: "openai.png",
            name: "GPT OSS 120B",
            nameShort: "GPT OSS",
            description: "",
            details: "",
            parameters: "",
            type: "chat",
            chat: true,
            paid: false,
            multimodal: true,
            toolCalling: nil,
            chatConfig: ChatModelConfig(
                contextWindowTokens: 64_000,
                attributes: nil,
                descriptionShort: nil,
                reasoningConfig: nil
            )
        )
    )

    private static func makeSource() -> Chat {
        let image = Attachment(
            id: "att-image",
            type: .image,
            fileName: "a.png",
            mimeType: "image/png",
            base64: "IMAGEBYTES",
            fileSize: 10,
            encryptionKey: "server-key"
        )
        let document = Attachment(
            id: "att-doc",
            type: .document,
            fileName: "notes.txt",
            textContent: "hello",
            fileSize: 5
        )
        var source = Chat(
            id: "chat-source",
            title: "Trip planning",
            titleState: .generated,
            messages: [
                Message(role: .user, turnId: "t1", content: "Here is a photo", attachments: [image, document]),
                Message(role: .assistant, turnId: "t1", content: "Nice photo", thoughts: "looking"),
                Message(role: .user, turnId: "t2", content: "Second question"),
            ],
            pendingRecoveries: [
                PendingRecoveryEnvelope(
                    v: 1,
                    turnId: "t1",
                    keyId: "key-1",
                    createdAt: "2026-01-01T00:00:00.000Z",
                    expiresAt: "2026-01-08T00:00:00.000Z",
                    nonce: "nonce",
                    ciphertext: "ciphertext"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1_000),
            modelType: model,
            language: "en",
            userId: "user-1",
            syncVersion: 7,
            syncedAt: Date(timeIntervalSince1970: 2_000),
            locallyModified: false,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            formatVersion: 2,
            isLocalOnly: true,
            projectId: "project-1",
            promptPresetId: "preset-1",
            webSearchEnabled: false
        )
        source.clock = 5
        source.writer = "device-a"
        source.clockVersion = 7
        source.hasActiveStream = true
        return source
    }

    @Test func keepsTheLeadingMessagesAndConversationSettingsUnderANewIdentity() throws {
        let source = Self.makeSource()
        let fork = try source.forked(throughMessageIndex: 1, id: "chat-fork")

        #expect(fork.id == "chat-fork")
        #expect(fork.title == "Trip planning (fork)")
        #expect(fork.titleState == .manual)
        #expect(fork.messages.map(\.content) == ["Here is a photo", "Nice photo"])
        #expect(fork.messages[1].thoughts == "looking")
        #expect(fork.messages.map(\.id) == Array(source.messages.prefix(2)).map(\.id))
        #expect(fork.modelType.id == source.modelType.id)
        #expect(fork.language == "en")
        #expect(fork.userId == "user-1")
        #expect(fork.isLocalOnly)
        #expect(fork.projectId == "project-1")
        #expect(fork.promptPresetId == "preset-1")
        #expect(fork.webSearchEnabled == false)
        #expect(fork.createdAt > source.createdAt)
        #expect(fork.updatedAt == fork.createdAt)
    }

    @Test func leavesSourceBookkeepingBehind() throws {
        let fork = try Self.makeSource().forked(throughMessageIndex: 2)

        #expect(fork.syncVersion == 0)
        #expect(fork.syncedAt == nil)
        #expect(fork.locallyModified)
        #expect(fork.clock == nil)
        #expect(fork.writer == nil)
        #expect(fork.clockVersion == nil)
        #expect(fork.pendingRecoveries == nil)
        #expect(fork.hasActiveStream == false)
        #expect(fork.formatVersion == nil)
        #expect(fork.pendingSave == false)
    }

    @Test func detachesAttachmentsFromSourceStorageWhileKeepingTheirBytes() throws {
        let source = Self.makeSource()
        let fork = try source.forked(throughMessageIndex: 0)
        let forked = fork.messages[0].attachments

        #expect(forked.count == 2)
        #expect(forked[0].id != "att-image")
        #expect(forked[0].encryptionKey == nil)
        #expect(forked[0].base64 == "IMAGEBYTES")
        #expect(forked[0].fileName == "a.png")
        #expect(forked[1].id != "att-doc")
        #expect(forked[1].textContent == "hello")
        #expect(source.messages[0].attachments[0].id == "att-image")
        #expect(source.messages[0].attachments[0].encryptionKey == "server-key")
    }

    @Test func rejectsAForkPointOutsideTheConversation() {
        let source = Self.makeSource()
        #expect(throws: ChatForkError.messageIndexOutOfRange) {
            try source.forked(throughMessageIndex: -1)
        }
        #expect(throws: ChatForkError.messageIndexOutOfRange) {
            try source.forked(throughMessageIndex: 3)
        }
    }

    @Test func forkTitleIsIdempotentAndFallsBackToThePlaceholder() {
        #expect(Chat.forkTitle(for: "Trip planning") == "Trip planning (fork)")
        #expect(Chat.forkTitle(for: "Trip planning (fork)") == "Trip planning (fork)")
        #expect(Chat.forkTitle(for: "  ") == "\(Chat.placeholderTitle) (fork)")
    }

    @Test func pendingSaveIsTransientAndSurfacesOnTheSummary() throws {
        var chat = Self.makeSource()
        chat.pendingSave = true

        #expect(ChatListSummary(from: chat).pendingSave)

        let decoded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
        #expect(decoded.pendingSave == false)
    }
}
