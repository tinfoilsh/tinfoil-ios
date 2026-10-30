import Foundation
import Testing
@testable import TinfoilChat

/// A control plane that issues one free key.
private struct FreeKeyControlPlane: ControlPlaneTransport {
    func get(_ path: String, identity: String?) async throws -> ControlPlaneAnswer {
        let body = #"{"key":"free_test","is_free_tier":true,"expires_at":"2999-01-01T00:00:00Z"}"#
        return ControlPlaneAnswer(status: 200, headers: [:], body: Data(body.utf8))
    }
}

@Suite("Chats the previous client kept")
@MainActor
struct LegacyDeviceChatsTests {
    private static func write(_ chat: [String: Any], into directory: URL) async throws {
        let sealed = try await DeviceEncryptionService.shared.encryptData(try JSONSerialization.data(withJSONObject: chat))
        try JSONEncoder().encode(sealed).write(to: directory.appendingPathComponent("\(chat["id"] as! String).enc"))
    }

    private static func oldChat(id: String, image: String) -> [String: Any] {
        ["id": id, "title": "Old", "createdAt": 0.0, "messages": [
            ["id": "\(id)-m", "role": "user", "content": "Look", "timestamp": 0.0, "attachments": [
                ["id": "\(id)-img", "type": "image", "fileName": "a.png", "mimeType": "image/png", "base64": image],
            ]],
        ]]
    }

    @Test func aRefusedChatHoldsBackNoOtherAndConvertedImagesKeepTheirOriginals() async throws {
        let userId = "legacy-test-\(UUID().uuidString)"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("tinfoil/chats/\(userId)", isDirectory: true)
        let local = directory.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.write(Self.oldChat(id: "refused", image: "UkVGVVNFRA=="), into: local)
        try await Self.write(Self.oldChat(id: "kept", image: "T1JJR0lOQUw="), into: local)

        let refusal = Answers.refusal(413, code: "THREAD_TOO_LARGE", action: "revise")
        let converted = Answers.json(["threads": [[
            "id": "kept", "title": "Old", "createdAt": "2001-01-01T00:00:00Z", "messages": [
                ["id": "kept-m", "role": "user", "createdAt": "2001-01-01T00:00:00Z", "content": "Look", "attachments": [
                    ["id": "kept-img", "kind": "image", "fileName": "a.png", "mimeType": "image/jpeg", "base64": "c21hbGw="],
                ]],
            ],
        ]]])
        let answer: ScriptedTransport.Answer = { request in
            let row = (request.json["threads"] as? [[String: Any]])?.first
            return try row?["id"] as? String == "refused" ? refusal(request) : converted(request)
        }
        let transport = ScriptedTransport([answer, answer])
        let controlPlane = FreeKeyControlPlane()
        let credentials = HarnessCredentialProvider(
            identity: { _ in nil },
            chatAccess: ChatAccessCache(controlPlane: controlPlane) { _ in },
            anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
        )
        let account = HarnessAccount(
            userId: nil,
            client: HarnessClient(credentials: credentials, transport: transport, languages: { ["en"] }),
            credentials: credentials,
            keyBytes: { nil },
            settings: MemoryProfileStorage(),
            cloudSync: false
        )
        let store = DeviceThreadStore(directory: nil)

        await LegacyDeviceChats.upgrade(userId: userId, account: account, into: store)

        #expect(await transport.requests.count == 2)
        #expect(try await store.get("kept") != nil)
        #expect(try await store.originals("kept", attachmentIds: ["kept-img"])["kept-img"] == AttachmentOriginal(base64: "T1JJR0lOQUw=", mimeType: "image/png"))
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("kept.enc").path))
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("refused.enc").path))
    }
}
