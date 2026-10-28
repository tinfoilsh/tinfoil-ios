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

@MainActor
private struct Fixture {
    let transport: ScriptedTransport
    let account: HarnessAccount
    let session: ChatSession

    /// A signed-out caller, whose chats live in memory, or an account with
    /// cloud sync whose key is held.
    init(userId: String? = nil, answers: [ScriptedTransport.Answer]) {
        transport = ScriptedTransport(answers)
        let controlPlane = FreeKeyControlPlane()
        let credentials = HarnessCredentialProvider(
            identity: { _ in userId == nil ? nil : "jwt" },
            chatAccess: ChatAccessCache(controlPlane: controlPlane) { _ in },
            anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
        )
        let client = HarnessClient(credentials: credentials, transport: transport, languages: { ["en"] })
        account = HarnessAccount(
            userId: userId,
            client: client,
            credentials: credentials,
            keyBytes: { Data(repeating: 7, count: 32) },
            settings: MemoryProfileStorage(),
            cloudSync: userId != nil
        )
        session = ChatSession(account: account, device: DeviceThreadStore(directory: nil), cache: ChatListCache(directory: nil), receipts: nil)
    }
}

private let threadId = "0000000000001_00000000-0000-4000-8000-000000000001"

/// The session the harness opens for a signed-in account.
private let signedInSession: [String: Any] = [
    "protocol": ["version": 1, "minimum": 1], "user": ["id": "user-1", "anonymous": false], "rateLimit": ["kind": NSNull()],
    "models": [], "auto": ["default": "", "levels": []], "defaultModel": "gpt-oss-120b", "widgets": [], "profileDefaults": [:],
    "composer": ["attachments": [], "projectDocuments": [], "pasteAsFileChars": 1000, "dictationMaxSeconds": 60],
    "presets": [], "features": [:],
]

private func summary(id: String = threadId, title: String = "Kept title", titleState: String = "generated", messageCount: Int = 1) -> [String: Any] {
    ["id": id, "title": title, "titleState": titleState, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": NSNull(),
     "activityAt": "2026-01-01T00:00:00Z", "projectId": NSNull(), "model": "kimi-k3", "webSearchEnabled": false, "pinned": false,
     "contextUsage": NSNull(), "activeRun": NSNull(), "messageCount": messageCount]
}

private func record(id: String = threadId, messages: [[String: Any]]) -> [String: Any] {
    ["id": id, "title": "Kept title", "titleState": "generated", "createdAt": "2026-01-01T00:00:00Z", "model": "kimi-k3",
     "projectId": NSNull(), "presetId": NSNull(), "pinned": false, "webSearchEnabled": false, "messages": messages,
     "activeRun": NSNull(), "recordVersion": 1, "aLaterMember": "kept"]
}

/// A run that answers "Second answer." and returns the device chat whole.
private func deviceRun(id: String, question: String, questionId: String) -> [[String: Any]] {
    let reply = "msg_5"
    let messages: [[String: Any]] = [
        ["id": questionId, "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": question, "attachments": []],
        ["id": reply, "role": "assistant", "createdAt": "2026-01-01T00:00:00Z", "content": "Second answer.", "model": "kimi-k3",
         "modelDisplayName": "Kimi K3", "timeline": [["id": "\(reply)_content_0", "type": "content", "content": "Second answer."]]],
    ]
    return [
        ["type": "RUN_STARTED", "timestamp": "2026-01-01T00:00:00Z", "threadId": id, "runId": "run_2", "instance": "i"],
        ["type": "MESSAGES_SNAPSHOT", "timestamp": "2026-01-01T00:00:01Z", "messages": [messages[0]], "hasOlder": false],
        ["type": "STATE_SNAPSHOT", "timestamp": "2026-01-01T00:00:02Z", "snapshot": ["thread": summary(id: id), "queue": [], "rateLimit": ["kind": NSNull()]]],
        ["type": "TEXT_MESSAGE_CHUNK", "timestamp": "2026-01-01T00:00:03Z", "messageId": reply, "role": "assistant", "delta": "Second answer."],
        ["type": "RUN_FINISHED", "timestamp": "2026-01-01T00:00:05Z", "threadId": id, "runId": "run_2", "metadata": [
            "messages": [["id": reply, "model": "kimi-k3", "modelDisplayName": "Kimi K3", "usage": ["promptTokens": 1, "completionTokens": 2], "isError": false, "isInterrupted": false]],
            "thread": record(id: id, messages: messages),
        ]],
    ]
}

@Suite("Chat session")
@MainActor
struct ChatSessionTests {
    @Test func aSignedOutCallersTurnCarriesTheChatAndStoresTheReply() async throws {
        let fixture = Fixture(answers: [])
        let session = fixture.session
        session.newChat()
        #expect(session.open.local)
        #expect(session.open.id == nil)
        // The turn's answer depends on the id the session picks, so it is
        // scripted once the request arrives.
        let transport = fixture.transport
        await transport.push { request in
            let turn = request.json
            return Answers.events(deviceRun(id: turn["threadId"] as! String, question: "second question", questionId: turn["clientRequestId"] as! String))(request)
        }
        let finished = await session.send(TurnFields(kind: .send, content: "second question", options: TurnOptions(model: "kimi-k3")))
        #expect(finished)
        let request = try #require(await transport.requests.first)
        #expect(request.route == .turn)
        #expect(request.headers["Authorization"] == "Bearer free_test")
        let turn = request.json
        #expect(turn["local"] as? Bool == true)
        #expect(turn["key"] == nil)
        #expect(turn["content"] as? String == "second question")
        // A new chat has no copy to send; the harness makes it.
        #expect(turn["thread"] == nil)
        #expect((turn["options"] as? [String: Any])?["model"] as? String == "kimi-k3")
        // Every turn is scoped to the caller's prompt cache as it is sent.
        let secret = try #require(PromptCacheSecret.secret(userId: nil))
        #expect((turn["options"] as? [String: Any])?["cacheSecret"] as? String == secret)
        let opened = try #require(session.open.id)
        #expect(turn["threadId"] as? String == opened)
        #expect(session.open.unsaved == nil)
        #expect(session.state.status == .idle)
        #expect(session.state.messages.map { $0.content ?? $0.timeline?.first?.content } == ["second question", "Second answer."])
        #expect(session.state.snapshot.thread?.title == "Kept title")
        // The device store holds the chat the run returned, under the id
        // the session chose, with every member the harness sent.
        let stored = try #require(try await session.device.get(opened))
        #expect(stored.messages.count == 2)
        #expect(stored["aLaterMember"]?.stringValue == "kept")
        #expect(stored.recordVersion == 1)
    }

    @Test func openingADeviceChatShowsItsMessagesAndUpdatesGoThroughTheHarness() async throws {
        let fixture = Fixture(answers: [])
        let session = fixture.session
        let stored = StoredThread(json: record(messages: [
            ["id": "u1", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "first question"],
            ["id": "a1", "role": "assistant", "createdAt": "2026-01-01T00:00:00Z", "content": "first answer", "timeline": [["id": "b1", "type": "content", "content": "first answer"]]],
        ]))!
        _ = try await session.device.add(stored, originals: [:])
        session.list.reloadDevice()
        #expect(try await session.openChat(threadId, local: true) == .opened)
        #expect(session.open.id == threadId)
        #expect(session.open.model == "kimi-k3")
        #expect(session.state.messages.map(\.id) == ["u1", "a1"])
        #expect(session.state.snapshot.thread?.titleState == .generated)

        var renamed = stored
        renamed["title"] = .string("Dogs")
        renamed["titleState"] = .string("manual")
        await fixture.transport.push(Answers.json(["thread": renamed.json]))
        let updated = try await session.update(threadId, ThreadPatch(title: "Dogs"))
        #expect(updated?.title == "Dogs")
        let request = try #require(await fixture.transport.requests.last)
        #expect(request.route == .update)
        #expect(request.json["local"] as? Bool == true)
        #expect(request.json["title"] as? String == "Dogs")
        #expect(request.json["thread"] != nil)
        #expect(try await session.device.get(threadId)?.title == "Dogs")
        #expect(session.state.snapshot.thread?.title == "Dogs")
    }

    @Test func aChatOpenedOnAnUnansweredMessageAsksTheHarnessToAnswerIt() async throws {
        let fixture = Fixture(answers: [])
        let session = fixture.session
        let stored = StoredThread(json: record(messages: [
            ["id": "u1", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "second question"],
        ]))!
        _ = try await session.device.add(stored, originals: [:])
        session.list.reloadDevice()
        #expect(try await session.openChat(threadId, local: true) == .opened)
        #expect(session.hasUnfinishedReply)

        await fixture.transport.push(Answers.events(deviceRun(id: threadId, question: "second question", questionId: "u1")))
        #expect(await session.retry())
        let request = try #require(await fixture.transport.requests.last)
        #expect(request.route == .turn)
        #expect(request.json["kind"] as? String == "retry")
        #expect(session.state.messages.count == 2)
        #expect(!session.hasUnfinishedReply)
    }

    @Test func aStoredChatIsNamedByItsKey() async throws {
        let window: [String: Any] = summary().merging([
            "revision": "rev-1", "presetId": NSNull(), "flagged": false,
            "messages": [["id": "u1", "role": "user", "createdAt": "2026-01-01T00:00:00Z", "content": "first question"]],
            "hasOlder": false,
        ]) { $1 }
        let fixture = Fixture(userId: "user-1", answers: [Answers.json(window)])
        let session = fixture.session
        #expect(!session.open.local)
        #expect(try await session.openChat(threadId, local: false) == .opened)
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.route == .get)
        #expect(request.json["key"] as? String == Data(repeating: 7, count: 32).base64EncodedString())
        #expect(request.json["id"] as? String == threadId)
        #expect(session.state.messages.map(\.id) == ["u1"])

        await fixture.transport.push(Answers.events([
            ["type": "RUN_STARTED", "threadId": threadId, "runId": "run_3", "instance": "i"],
            ["type": "STATE_SNAPSHOT", "snapshot": ["thread": summary(messageCount: 3), "queue": [], "rateLimit": ["kind": NSNull()]]],
            ["type": "TEXT_MESSAGE_CHUNK", "messageId": "msg_6", "role": "assistant", "delta": "Hi."],
            ["type": "RUN_FINISHED", "threadId": threadId, "runId": "run_3", "metadata": [:]],
        ]))
        #expect(await session.send(TurnFields(kind: .send, content: "again")))
        let turn = try #require(await fixture.transport.requests.last)
        #expect(turn.route == .turn)
        #expect(turn.json["key"] as? String != nil)
        #expect(turn.json["local"] == nil)
        #expect(turn.json["thread"] == nil)
        #expect(session.state.messages.map(\.id).contains("msg_6"))
        #expect(session.state.messages.last?.timeline?.first?.content == "Hi.")
    }

    @Test func aRefusedTurnLeavesTheChatAsItWasWithTheError() async throws {
        let fixture = Fixture(answers: [Answers.refusal(429, code: "QUOTA_EXHAUSTED", action: "wait")])
        let session = fixture.session
        session.newChat()
        #expect(!(await session.send(TurnFields(kind: .send, content: "hello"))))
        #expect(session.state.error?.code == "QUOTA_EXHAUSTED")
        #expect(session.state.error?.action == .wait)
        #expect(session.state.status == .error)
        // The question stays, to be sent again, and the chat is kept on the
        // device from it.
        #expect(session.state.messages.map { $0.content } == ["hello"])
        #expect(session.open.unsaved == nil)
        #expect(session.controller.pending?.input.content == "hello")
        #expect(try await session.device.get(session.open.id!)?.messages.count == 1)
    }

    @Test func aChatOnThisDeviceSendsWhileTheAccountsKeyIsRefused() async throws {
        let fixture = Fixture(userId: "user-1", answers: [Answers.json(signedInSession), Answers.refusal(409, code: HarnessErrorCode.keyMismatch, action: "unlock")])
        let session = fixture.session
        // A chat on this device sends with the settings this device kept,
        // while a stored chat waits for the account's.
        session.newChat(local: true)
        #expect(session.sendBlock == nil)
        session.newChat(local: false)
        #expect(session.sendBlock == .loading)
        try await fixture.account.refresh()
        #expect(fixture.account.keyLocked)
        #expect(session.sendBlock == .locked)
        session.newChat(local: true)
        #expect(session.sendBlock == nil)
        session.newChat(local: false)
        session.setTemporary(true)
        #expect(session.sendBlock == nil)
    }

    @Test func aStoredChatWaitsForSettingsThatFailedToLoad() async throws {
        let fixture = Fixture(userId: "user-1", answers: [Answers.json(signedInSession), Answers.refusal(503, code: "UPSTREAM_UNAVAILABLE", action: "retry")])
        let session = fixture.session
        try await fixture.account.refresh()
        session.newChat(local: false)
        #expect(session.sendBlock == .failed)
        session.newChat(local: true)
        #expect(session.sendBlock == nil)
    }

    @Test func anAccountSignedOutOfSendsNothingMore() async throws {
        let fixture = Fixture(userId: "user", answers: [])
        fixture.account.dispose()
        await #expect(throws: CancellationError.self) {
            let _: RawJSON = try await fixture.account.post(.session, keyless: true)
        }
        #expect(await fixture.transport.requests.isEmpty)
    }

    @Test func anUploadIsTheAttachmentTheHarnessConvertedItTo() async throws {
        let sessionAnswer: [String: Any] = [
            "protocol": ["version": 1, "minimum": 1], "user": ["id": "", "anonymous": true], "rateLimit": ["kind": NSNull()],
            "models": [], "auto": ["default": "", "levels": []], "defaultModel": "gpt-oss-120b", "widgets": [], "profileDefaults": [:],
            "composer": ["attachments": [["accept": [".txt"], "maxBytes": 1000]], "projectDocuments": [], "pasteAsFileChars": 1000, "dictationMaxSeconds": 60],
            "presets": [], "features": [:],
        ]
        let converted: [String: Any] = ["id": "att_1", "kind": "document", "fileName": "notes.txt", "mimeType": "text/plain", "textContent": "Notes"]
        let fixture = Fixture(answers: [Answers.json(sessionAnswer), Answers.json(["attachment": converted])])
        try await fixture.account.refresh()
        let attachment = try await fixture.session.upload(Data("Notes".utf8), fileName: "notes.txt", mimeType: "text/plain")
        #expect(attachment.id == "att_1")
        #expect(attachment.textContent == "Notes")
        #expect(await fixture.transport.requests.last?.route == .attachmentUpload)
    }
}
