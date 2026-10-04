import Foundation
import OpenAI
import Testing
@testable import TinfoilChat

@Suite("Document attachment offloading")
struct DocumentAttachmentPayloadTests {
    private actor UploadRecorder {
        var events: [String] = []
        var keys: [String] = []
        var payloads: [Data] = []
        let failSecond: Bool

        init(failSecond: Bool = false) { self.failSecond = failSecond }

        func put(_ request: EnclaveAttachmentPutRequest) throws -> EnclaveAttachmentPutResponse {
            events.append("put")
            keys.append(request.idempotencyKey)
            payloads.append(try #require(Data(base64Encoded: request.plaintext)))
            if failSecond && payloads.count == 2 { throw DocumentAttachmentError.unavailable }
            return EnclaveAttachmentPutResponse(ok: true, id: "server-\(payloads.count)", attKey: "key")
        }

        func persist(_ rewrite: CloudStorageService.AttachmentRewrite) {
            events.append("persist:\(rewrite.serverId)")
        }
    }

    private func document(text: String? = nil, pages: [DocumentPage]? = nil, key: String? = "key") -> Attachment {
        Attachment(id: "document", type: .document, fileName: "scan.pdf", textContent: text,
                   pages: pages, encryptionKey: key, processingState: .completed)
    }

    private func message(_ attachment: Attachment) -> Message {
        Message(id: "message", role: .user, content: "Summarize", attachments: [attachment])
    }

    @Test func decodesWebPayloadAndPreservesPagesInChatStorage() throws {
        let json = #"{"textContent":"Résumé","pages":[{"page":0,"text":"Text","is_scanned":false},{"page":1,"text":"","image":"AQID","is_scanned":true}]}"#
        let payload = try JSONDecoder().decode(DocumentAttachmentPayload.self, from: Data(json.utf8))
        #expect(payload.textContent == "Résumé")
        #expect(payload.pages?[0].image == "")
        #expect(payload.pages?[1].isScanned == true)
        let attachment = document(text: payload.textContent, pages: payload.pages)
        let restored = try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(attachment))
        #expect(restored == attachment)
        let encoded = try DocumentAttachmentPayload.encode(restored)
        #expect(try JSONDecoder().decode(DocumentAttachmentPayload.self, from: encoded) == payload)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("scan.pdf"))
    }

    @Test(arguments: ["{}", "null", #"{"textContent":null}"#, #"{"pages":null}"#,
                      #"{"pages":[{"page":-1,"text":"x","is_scanned":false}]}"#,
                      #"{"pages":[{"page":1,"text":"x","is_scanned":true}]}"#])
    func rejectsInvalidPayload(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DocumentAttachmentPayload.self, from: Data(json.utf8))
        }
    }

    @Test func acceptsEmptyExtractedContent() throws {
        let text = try DocumentAttachmentPayload(textContent: "")
        let pages = try DocumentAttachmentPayload(pages: [])
        #expect(text.textContent == "")
        #expect(pages.pages == [])
    }

    @Test func persistsFirstDocumentBeforeALaterUploadFailure() async throws {
        var second = document(text: "second", key: nil)
        second.id = "second"
        let chat = Chat(id: "chat", title: "Documents", messages: [
            message(document(text: "first", key: nil)), message(second)
        ], modelType: ChatForkTests.model)
        var stored = StoredChat(from: chat, syncVersion: 1)
        let recorder = UploadRecorder(failSecond: true)

        await #expect(throws: DocumentAttachmentError.self) {
            try await CloudStorageService.uploadAttachments(
                &stored, offloadDocuments: true,
                onAttachmentUploaded: { await recorder.persist($0) },
                put: { try await recorder.put($0) }
            )
        }

        let events = await recorder.events
        #expect(events == ["put", "persist:server-1", "put"])
        #expect(stored.messages[0].attachments[0].id == "server-1")
        #expect(stored.messages[0].attachments[0].encryptionKey == "key")
        #expect(stored.messages[1].attachments[0].encryptionKey == nil)
        #expect(chat.messages[0].attachments[0].id == "document")
        let payloads = await recorder.payloads
        #expect(try JSONDecoder().decode(DocumentAttachmentPayload.self, from: payloads[0]).textContent == "first")
    }

    @Test func documentUploadsAreGatedAndReuseDeterministicIdentities() async throws {
        let chat = Chat(id: "chat", title: "Document", messages: [message(document(text: "content", key: nil))], modelType: ChatForkTests.model)
        var stored = StoredChat(from: chat, syncVersion: 1)
        let recorder = UploadRecorder()
        let skipped = try await CloudStorageService.uploadAttachments(
            &stored, offloadDocuments: false,
            onAttachmentUploaded: { await recorder.persist($0) },
            put: { try await recorder.put($0) }
        )
        #expect(skipped.isEmpty)
        let skippedEvents = await recorder.events
        #expect(skippedEvents.isEmpty)
        for _ in 0..<2 {
            var fresh = StoredChat(from: chat, syncVersion: 1)
            let rewrites = try await CloudStorageService.uploadAttachments(
                &fresh, offloadDocuments: true,
                onAttachmentUploaded: { await recorder.persist($0) },
                put: { try await recorder.put($0) }
            )
            #expect(rewrites.count == 1)
        }
        let keys = await recorder.keys
        #expect(keys.count == 2)
        #expect(keys[0] == keys[1])
    }

    @Test func stripsOnlyUploadedDocumentsAndKeepsLocalContent() {
        let source = [message(document(text: "content"))]
        var wire = source
        CloudStorageService.stripAttachmentPayloads(&wire, offloadDocuments: true)
        #expect(wire[0].attachments[0].textContent == nil)
        #expect(wire[0].attachments[0].encryptionKey == "key")
        #expect(source[0].attachments[0].textContent == "content")
        var inline = [message(document(text: "not uploaded", key: nil))]
        CloudStorageService.stripAttachmentPayloads(&inline, offloadDocuments: true)
        #expect(inline[0].attachments[0].textContent == "not uploaded")
        var beforeCutover = source
        CloudStorageService.stripAttachmentPayloads(&beforeCutover, offloadDocuments: false)
        #expect(beforeCutover[0].attachments[0].textContent == "content")
    }

    @Test func hydratesMissingContentWithoutFetchingInlineDocuments() async throws {
        let source = [message(document()), message(document(text: "local", key: nil))]
        var fetches = 0
        let hydrated = try await DocumentAttachmentPayload.hydrate(source) { attachment in
            fetches += 1
            #expect(attachment.encryptionKey == "key")
            return Data(#"{"textContent":"from blob"}"#.utf8)
        }
        #expect(fetches == 1)
        #expect(hydrated[0].attachments[0].textContent == "from blob")
        #expect(hydrated[1].attachments[0].textContent == "local")
        #expect(source[0].attachments[0].textContent == nil)
    }

    @Test func missingOrInvalidDocumentsAbortHydration() async {
        for source in [document(), document(key: nil)] {
            await #expect(throws: (any Error).self) {
                try await DocumentAttachmentPayload.hydrate([message(source)]) { _ in Data("{}".utf8) }
            }
        }
        await #expect(throws: DocumentAttachmentError.self) {
            try await DocumentAttachmentPayload.hydrate([message(document())]) { _ in
                throw DocumentAttachmentError.unavailable
            }
        }
        await #expect(throws: CancellationError.self) {
            try await DocumentAttachmentPayload.hydrate([message(document())]) { _ in
                throw CancellationError()
            }
        }
    }

    @Test func mergesFetchedContentWithoutOverwritingEditsOrDifferentKeys() {
        let hydrated = [message(document(text: "fetched"))]
        var current = message(document())
        current.content = "Edited while loading"
        let merged = DocumentAttachmentPayload.merging(hydrated, into: [current])
        #expect(merged[0].content == current.content)
        #expect(merged[0].attachments[0].textContent == "fetched")
        let different = DocumentAttachmentPayload.merging(hydrated, into: [message(document(key: "other-key"))])
        #expect(different[0].attachments[0].textContent == nil)
        let edited = DocumentAttachmentPayload.merging(hydrated, into: [message(document(text: "new content"))])
        #expect(edited[0].attachments[0].textContent == "new content")
    }

    @MainActor
    @Test func scannedPagesAndPageTextReachThePrompt() throws {
        let attachment = document(pages: [DocumentPage(page: 1, text: "Page text", image: "AQID", isScanned: true)])
        let query = ChatQueryBuilder.buildQuery(modelId: "gpt-oss-120b", systemPrompt: "", rules: "",
                                              conversationMessages: [message(attachment)], isMultimodal: true,
                                              genUIEnabled: false)
        let json = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
        #expect(json.contains("Page text"))
        #expect(json.contains("AQID"))
        #expect(json.contains("image_url"))
        #expect(TokenEstimation.estimateMessageTokens(message(attachment)) > TokenEstimation.estimateTokenCount("Summarize"))
    }

    @Test func sharesKeepDocumentReferencesWithoutDuplicatingPayload() throws {
        let payload = SharePayloadBuilder.build(messages: [message(document(text: "large document"))], chatTitle: "Chat", chatCreatedAt: nil)
        let attachment = try #require(payload.messages[0].attachments?.first)
        #expect(attachment.encryptionKey == "key")
        #expect(attachment.textContent == nil)
        #expect(payload.messages[0].documentContent == nil)
        let inline = SharePayloadBuilder.build(messages: [message(document(text: "local", key: nil))], chatTitle: "Chat", chatCreatedAt: nil)
        #expect(inline.messages[0].documentContent?.contains("local") == true)
    }

    @Test func cutoverRequiresExplicitRemoteProtocolActivation() throws {
        func config(_ field: String) throws -> RemoteConfig {
            try JSONDecoder().decode(RemoteConfig.self, from: Data("{\"chatConfig\":{\"systemPrompt\":\"\",\"rules\":\"\"},\"minSupportedVersion\":\"2.11.0\"\(field)}".utf8))
        }
        #expect(try config("").effectiveSyncProtocolVersion == 2)
        #expect(try !config("").documentAttachmentsEnabled)
        #expect(try config(",\"syncProtocolVersion\":3").documentAttachmentsEnabled)
        #expect(try config(",\"syncProtocolVersion\":4").effectiveSyncProtocolVersion == 3)
    }
}
