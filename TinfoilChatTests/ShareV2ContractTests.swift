//
//  ShareV2ContractTests.swift
//  TinfoilChatTests
//


import Foundation
import Testing
@testable import TinfoilChat

@Suite("Enclave v2 sharing")
struct ShareV2ContractTests {
    private let shareKey = String(repeating: "ab", count: 32)

    @Test func encodesExactWebPayloadJSONAndBase64() throws {
        let message = Message(
            role: .user,
            content: "Hello",
            timestamp: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let payload = SharePayloadBuilder.build(
            messages: [message],
            chatTitle: "",
            chatCreatedAt: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let json = try SharePayloadBuilder.encode(payload)
        let expected = #"{"createdAt":1700000000000,"messages":[{"content":"Hello","role":"user","timestamp":1700000001000}],"title":"Shared Chat","v":1}"#

        #expect(String(decoding: json, as: UTF8.self) == expected)
        #expect(dataToBase64(Data(#"{"v":1}"#.utf8)) == "eyJ2IjoxfQ==")
    }

    @Test func preservesWebMessageFields() throws {
        var message = Message(
            role: .assistant,
            content: "Answer",
            modelDisplayName: "GPT-OSS 120B",
            thoughts: "Reasoning",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        message.thinkingDuration = 1.25
        message.isError = false
        message.timeline = [.object(["type": .string("content"), "content": .string("Answer")])]
        message.annotations = [Annotation(
            type: "url_citation",
            url_citation: URLCitation(title: "Source", url: "https://example.com", start_index: 0, end_index: 6)
        )]
        message.webSearchState = WebSearchState(
            query: "query",
            status: .completed,
            sources: [WebSearchSource(id: "transient-source-id", title: "Source", url: "https://example.com")],
            reason: "done"
        )
        message.webSearchBeforeThinking = true
        message.urlFetches = [URLFetchState(id: "fetch-1", url: "https://example.com/page", status: .completed)]
        message.isThinking = true
        message.isStreaming = true
        message.streamError = "transient"
        message.segments = [.text("transient")]
        message.toolCalls = [GenUIToolCall(id: "tool-1", name: "widget", arguments: "{}")]

        let data = try SharePayloadBuilder.encode(SharePayloadBuilder.build(
            messages: [message],
            chatTitle: "Title",
            chatCreatedAt: Date(timeIntervalSince1970: 50)
        ))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let encoded = try #require(messages.first)

        #expect(encoded["modelDisplayName"] as? String == "GPT-OSS 120B")
        #expect(encoded["thoughts"] as? String == "Reasoning")
        #expect(encoded["thinkingDuration"] as? Double == 1.25)
        #expect(encoded["timeline"] != nil)
        #expect(encoded["annotations"] != nil)
        #expect(encoded["webSearchBeforeThinking"] as? Bool == true)
        #expect(encoded["urlFetches"] != nil)
        let webSearch = try #require(encoded["webSearch"] as? [String: Any])
        let sources = try #require(webSearch["sources"] as? [[String: Any]])
        #expect(Set(sources[0].keys) == ["title", "url"])
        #expect(encoded["isThinking"] == nil)
        #expect(encoded["isStreaming"] == nil)
        #expect(encoded["streamError"] == nil)
        #expect(encoded["segments"] == nil)
        #expect(encoded["toolCalls"] == nil)
    }

    @Test func includesOnlyWebAttachmentMetadata() throws {
        let fullImageBase64 = String(repeating: "FULL_IMAGE_BYTES", count: 20)
        let attachment = Attachment(
            id: "attachment-1",
            type: .image,
            fileName: "photo.png",
            mimeType: "image/png",
            base64: fullImageBase64,
            thumbnailBase64: "THUMBNAIL",
            textContent: "caption",
            description: "Photo",
            fileSize: 999,
            sharedImportRequestID: UUID(),
            encryptionKey: "attachment-key",
            processingState: .processing
        )
        let message = Message(role: .user, content: "Look", attachments: [attachment])
        let data = try SharePayloadBuilder.encode(SharePayloadBuilder.build(
            messages: [message],
            chatTitle: "Attachment",
            chatCreatedAt: Date(timeIntervalSince1970: 1)
        ))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let attachments = try #require(messages[0]["attachments"] as? [[String: Any]])
        let encoded = attachments[0]

        #expect(Set(encoded.keys) == [
            "id", "type", "fileName", "mimeType", "thumbnailBase64",
            "encryptionKey", "textContent", "description",
        ])
        #expect(encoded["thumbnailBase64"] as? String == "THUMBNAIL")
        #expect(!String(decoding: data, as: UTF8.self).contains(fullImageBase64))
    }

    @Test func validatesExactCiphertextBytesAndBuildsLink() throws {
        let ciphertext = Data([0x00, 0x01, 0x02, 0xff])
        let validated = try ShareV2Contract.validate(EnclaveShareSealResponse(
            ok: true,
            shareKey: shareKey,
            ciphertext: "AAEC/w=="
        ))

        #expect(validated == ValidatedShareSeal(shareKey: shareKey, ciphertext: ciphertext))
        #expect(ShareV2Contract.shareURL(chatId: "chat-id", shareKey: validated.shareKey)
            == "https://chat.tinfoil.sh/share/chat-id#v2:\(shareKey)")
    }

    @Test func rejectsNonContractSealResponses() {
        #expect(throws: ShareContractError.self) {
            try ShareV2Contract.validate(EnclaveShareSealResponse(
                ok: false,
                shareKey: shareKey,
                ciphertext: "AAEC/w=="
            ))
        }
        #expect(throws: ShareContractError.self) {
            try ShareV2Contract.validate(EnclaveShareSealResponse(
                ok: true,
                shareKey: String(repeating: "AB", count: 32),
                ciphertext: "AAEC/w=="
            ))
        }
        #expect(throws: ShareContractError.self) {
            try ShareV2Contract.validate(EnclaveShareSealResponse(
                ok: true,
                shareKey: shareKey,
                ciphertext: "not-base64"
            ))
        }
    }

    @Test func uploadsExactCiphertextAsFormatOneBinary() {
        let ciphertext = Data([0xde, 0xad, 0xbe, 0xef])
        let request = ShareAPIService.makeUploadRequest(
            url: URL(string: "https://api.tinfoil.sh/api/shares/chat-id")!,
            encryptedData: ciphertext,
            token: "token"
        )

        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "X-Format-Version") == "1")
        #expect(request.httpBody == ciphertext)
    }
}
