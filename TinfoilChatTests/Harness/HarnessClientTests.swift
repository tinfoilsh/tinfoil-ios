import Foundation
import Testing
import TinfoilAI
@testable import TinfoilChat

/// A flag that waiters wake on, or give up on when cancelled.
private actor Signal {
    private var raised = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func raise() {
        raised = true
        waiters.values.forEach { $0.resume() }
        waiters.removeAll()
    }

    /// Whether the flag is raised within the time given.
    func raised(within seconds: Double) async -> Bool {
        if raised { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Whether the flag was raised, rather than the wait cancelled.
    private func wait() async -> Bool {
        if raised { return true }
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[waiter] = $0 }
        } onCancel: {
            Task { await self.giveUp(waiter) }
        }
        return raised
    }

    private func giveUp(_ waiter: UUID) {
        waiters.removeValue(forKey: waiter)?.resume()
    }
}

private struct Ok: Decodable, Equatable {
    let ok: Bool
}

private struct Input: Encodable {
    var threadId: String
}

@Suite("Harness client")
struct HarnessClientTests {
    private static func json(_ status: Int, _ body: String) -> ScriptedTransport.Answer {
        { _ in .collected(status: status, headers: ["content-type": "application/json"], sealed: true, body: Data(body.utf8)) }
    }

    private static func events(_ text: String) -> ScriptedTransport.Answer {
        { _ in .collected(status: 200, headers: ["content-type": "text/event-stream"], sealed: true, body: Data(text.utf8)) }
    }

    private static func refusal(_ status: Int, code: String, action: String) -> ScriptedTransport.Answer {
        json(status, #"{"error":{"code":"\#(code)","message":"refused","action":"\#(action)"}}"#)
    }

    private static func client(
        _ transport: ScriptedTransport,
        _ credentials: ScriptedCredentials,
        languages: [String] = ["fr-CA", "en"]
    ) -> HarnessClient {
        HarnessClient(credentials: credentials, transport: transport, languages: { languages })
    }

    private static func failure(_ body: () async throws -> Void) async -> HarnessError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? HarnessError
        }
    }

    @Test func aSignedInRequestCarriesItsIdentityChatAccessAndLanguages() async throws {
        let transport = ScriptedTransport([Self.json(200, #"{"ok":true}"#)])
        let credentials = ScriptedCredentials(identities: ["clerk-jwt"], access: [.success("inference-key")])
        let client = Self.client(transport, credentials)
        let answer: Ok = try await client.post(.profileGet, Input(threadId: "t"))
        #expect(answer == Ok(ok: true))
        let request = try #require(await transport.requests.first)
        #expect(request.route == .profileGet)
        #expect(request.headers["Authorization"] == "Bearer clerk-jwt")
        #expect(request.headers[HarnessHeader.inferenceKey] == "inference-key")
        #expect(request.headers["Accept-Language"] == "fr-CA,en")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers[HarnessHeader.instance] == nil)
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"threadId":"t"}"#)
        #expect(await credentials.calls == [.identity(refresh: false), .chatAccess(identity: "clerk-jwt", refresh: false)])
    }

    @Test func aSignedOutRequestCarriesAFreeKeyAndNoChatAccess() async throws {
        let transport = ScriptedTransport([Self.json(200, #"{"ok":true}"#)])
        let credentials = ScriptedCredentials(identities: [nil], anonymousKeys: ["free_1"])
        let _: Ok = try await Self.client(transport, credentials).post(.session, Input(threadId: "t"))
        let request = try #require(await transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer free_1")
        #expect(request.headers[HarnessHeader.inferenceKey] == nil)
        #expect(await credentials.calls == [.identity(refresh: false), .anonymousKey(refresh: false)])
    }

    @Test func aRefusalIsReadByItsEnvelopeAndStatus() async throws {
        let transport = ScriptedTransport([Self.json(409, #"{"error":{"code":"LATER_CODE","message":"nope","action":"later","retryAfter":7}}"#)])
        let credentials = ScriptedCredentials(identities: ["jwt"], access: [.success("key")])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t")) }
        #expect(error == HarnessError(HarnessErrorBody(code: "LATER_CODE", message: "nope", action: .stop, retryAfter: 7), status: 409))
    }

    @Test func aRefusalWithoutTheEnvelopeIsOneTheClientCannotRead() async throws {
        let transport = ScriptedTransport([Self.json(502, "Bad Gateway")])
        let credentials = ScriptedCredentials(identities: ["jwt"], access: [.success("key")])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t")) }
        #expect(error == HarnessError(HarnessErrorBody.invalidResponse, status: 502))
    }

    @Test func aRefusalTheEnclaveDidNotSealIsALostConnectionTheClientDoesNotActOn() async throws {
        let envelope = #"{"error":{"code":"UNAUTHENTICATED","message":"Sign in again","action":"reauthenticate"}}"#
        let transport = ScriptedTransport([{ _ in .collected(status: 401, headers: ["content-type": "application/json"], sealed: false, body: Data(envelope.utf8)) }])
        let credentials = ScriptedCredentials(identities: ["jwt", "jwt-2"], access: [.success("key"), .success("key")])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t")) }
        #expect(error == HarnessError(HarnessErrorBody.unsealedRefusal, status: nil))
        #expect(await transport.requests.count == 1)
    }

    @Test func anAnswerThatIsNotTheProtocolsIsOneTheClientCannotRead() async throws {
        let transport = ScriptedTransport([Self.json(200, #"{"something":"else"}"#)])
        let credentials = ScriptedCredentials(identities: ["jwt"], access: [.success("key")])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t")) }
        #expect(error == HarnessError(HarnessErrorBody.invalidResponse, status: 200))
    }

    @Test func reauthenticatingSendsTheRequestAgainOnceWithAFreshIdentity() async throws {
        let transport = ScriptedTransport([
            Self.refusal(401, code: "UNAUTHENTICATED", action: "reauthenticate"),
            Self.json(200, #"{"ok":true}"#),
        ])
        let credentials = ScriptedCredentials(identities: ["old-jwt", "new-jwt"], access: [.success("key-1"), .success("key-2")])
        let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t"))
        let requests = await transport.requests
        #expect(requests.map { $0.headers["Authorization"] } == ["Bearer old-jwt", "Bearer new-jwt"])
        // The chat access was not refused, so it is minted again only by the
        // identity it belongs to, not refreshed.
        #expect(await credentials.calls == [
            .identity(refresh: false), .chatAccess(identity: "old-jwt", refresh: false),
            .identity(refresh: true), .chatAccess(identity: "new-jwt", refresh: false),
        ])
    }

    @Test func aSecondRefusalToReauthenticateFailsAsUnauthenticated() async throws {
        let transport = ScriptedTransport([
            Self.refusal(401, code: "UNAUTHENTICATED", action: "reauthenticate"),
            Self.refusal(401, code: "UNAUTHENTICATED", action: "reauthenticate"),
        ])
        let credentials = ScriptedCredentials(identities: ["jwt", "jwt-2"], access: [.success("k"), .success("k")])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t")) }
        #expect(error?.code == HarnessErrorCode.unauthenticated)
        #expect(error?.action == .reauthenticate)
        #expect(error?.status == 401)
        #expect(await transport.requests.count == 2)
    }

    @Test func anIdentityThatCannotBeRefreshedFailsAsUnauthenticated() async throws {
        let transport = ScriptedTransport([Self.refusal(401, code: "UNAUTHENTICATED", action: "reauthenticate")])
        let credentials = ScriptedCredentials(identities: ["jwt", nil], access: [.success("k")])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.get, Input(threadId: "t")) }
        #expect(error == HarnessError.unauthenticated)
    }

    @Test func aSignedOutCallerReauthenticatesWithAnotherFreeKey() async throws {
        let transport = ScriptedTransport([
            Self.refusal(401, code: "UNAUTHENTICATED", action: "reauthenticate"),
            Self.json(200, #"{"ok":true}"#),
        ])
        let credentials = ScriptedCredentials(identities: [nil, nil], anonymousKeys: ["free_1", "free_2"])
        let _: Ok = try await Self.client(transport, credentials).post(.session, Input(threadId: "t"))
        #expect(await transport.requests.map { $0.headers["Authorization"] } == ["Bearer free_1", "Bearer free_2"])
        #expect(await credentials.calls == [.identity(refresh: false), .anonymousKey(refresh: false), .anonymousKey(refresh: true)])
    }

    @Test func aRequestThatNeedsRefusedChatAccessFailsWithTheRefusal() async throws {
        // The request goes without the access the control plane refused; the
        // harness asks once to reauthenticate, and the refusal, kept until the
        // control plane says to ask again, is what the request fails with.
        let transport = ScriptedTransport([
            Self.refusal(401, code: "CREDENTIAL_REQUIRED", action: "reauthenticate"),
            Self.refusal(401, code: "CREDENTIAL_REQUIRED", action: "reauthenticate"),
        ])
        let quota = HarnessError(code: "QUOTA_EXHAUSTED", message: "hourly cap", action: .wait, status: 429)
        let credentials = ScriptedCredentials(identities: ["jwt", "jwt"], access: [.failure(quota), .failure(quota)])
        let error = await Self.failure { let _: Ok = try await Self.client(transport, credentials).post(.turn, Input(threadId: "t")) }
        #expect(error == quota)
        #expect(await transport.requests.map { $0.headers[HarnessHeader.inferenceKey] } == [nil, nil])
        #expect(await credentials.calls.last == .chatAccess(identity: "jwt", refresh: false))
    }

    @Test func chatAccessTheHarnessRefusedIsMintedAgain() async throws {
        let transport = ScriptedTransport([
            Self.refusal(401, code: "CREDENTIAL_REQUIRED", action: "reauthenticate"),
            Self.json(200, #"{"ok":true}"#),
        ])
        let credentials = ScriptedCredentials(identities: ["jwt", "jwt"], access: [.success("expired"), .success("fresh")])
        let _: Ok = try await Self.client(transport, credentials).post(.turn, Input(threadId: "t"))
        #expect(await transport.requests.map { $0.headers[HarnessHeader.inferenceKey] } == ["expired", "fresh"])
        #expect(await credentials.calls.last == .chatAccess(identity: "jwt", refresh: true))
    }

    @Test func aRunStreamNamesTheInstanceLaterRequestsAboutTheRunGoTo() async throws {
        let transport = ScriptedTransport([
            Self.events("id: 0\ndata: {\"type\":\"RUN_STARTED\",\"threadId\":\"t\",\"runId\":\"r\",\"instance\":\"node-7\"}\n\nid: 1\ndata: {\"type\":\"RUN_FINISHED\",\"threadId\":\"t\",\"runId\":\"r\",\"metadata\":{}}\n\n"),
            Self.json(200, #"{"ok":true}"#),
            Self.events("id: 2\ndata: {\"type\":\"RUN_FINISHED\",\"threadId\":\"t\",\"runId\":\"r\",\"metadata\":{}}\n\n"),
        ])
        let credentials = ScriptedCredentials(identities: ["jwt", "jwt", "jwt"], access: [.success("k"), .success("k"), .success("k")])
        let client = Self.client(transport, credentials)
        var ids: [Int?] = []
        for try await frame in try await client.events(.turn, Input(threadId: "t")) { ids.append(frame.id) }
        #expect(ids == [0, 1])
        let _: Ok = try await client.post(.cancel, Input(threadId: "t"), threadId: "t")
        for try await _ in try await client.events(.follow, Input(threadId: "t"), threadId: "t", lastEventId: 1) {}
        let requests = await transport.requests
        #expect(requests.map { $0.headers[HarnessHeader.instance] } == [nil, "node-7", "node-7"])
        #expect(requests.map { $0.headers[HarnessHeader.lastEventId] } == [nil, nil, "1"])
    }

    @Test func leavingARunStreamEndsItsResponse() async throws {
        let ended = Signal()
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("id: 0\ndata: {\"type\":\"RUN_STARTED\",\"threadId\":\"t\",\"runId\":\"r\",\"instance\":\"i\"}\n\n".utf8))
            continuation.onTermination = { _ in Task { await ended.raise() } }
        }
        let transport = ScriptedTransport([{ _ in HarnessResponse(status: 200, headers: ["content-type": "text/event-stream"], sealed: true, body: body) }])
        let credentials = ScriptedCredentials(identities: ["jwt"], access: [.success("k")])
        var seen = 0
        for try await _ in try await Self.client(transport, credentials).events(.turn, Input(threadId: "t")) {
            seen += 1
            break
        }
        #expect(seen == 1)
        #expect(await ended.raised(within: 2))
    }

    @Test func aRunThatDoesNotAnswerWithEventsIsNotAStream() async throws {
        let transport = ScriptedTransport([Self.json(200, #"{"ok":true}"#)])
        let credentials = ScriptedCredentials(identities: ["jwt"], access: [.success("k")])
        let error = await Self.failure { _ = try await Self.client(transport, credentials).events(.turn, Input(threadId: "t")) }
        #expect(error?.code == HarnessErrorCode.invalidStream)
    }

    @Test func anUploadSendsItsFieldsAndFileAsAForm() async throws {
        let transport = ScriptedTransport([Self.json(200, #"{"ok":true}"#)])
        let credentials = ScriptedCredentials(identities: ["jwt"], access: [.success("k")])
        let _: Ok = try await Self.client(transport, credentials).upload(
            .attachmentUpload, file: Data("PNG!".utf8), fileName: "a \"b\".png", mimeType: "image/png", fields: ["kind": "image"]
        )
        let request = try #require(await transport.requests.first)
        let contentType = try #require(request.headers["Content-Type"])
        let boundary = try #require(contentType.split(separator: "=").last.map(String.init))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let expected = "--\(boundary)\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nimage\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a \\\"b\\\".png\"\r\nContent-Type: image/png\r\n\r\nPNG!\r\n--\(boundary)--\r\n"
        #expect(String(decoding: request.body, as: UTF8.self) == expected)
    }
}
