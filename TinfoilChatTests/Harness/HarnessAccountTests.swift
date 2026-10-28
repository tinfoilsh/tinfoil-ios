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

/// The content key a test account reads, which a test can change.
@MainActor
private final class HeldKey {
    var bytes: Data? = Data(repeating: 7, count: 32)
}

private let sessionAnswer: [String: Any] = [
    "protocol": ["version": 1, "minimum": 1], "user": ["id": "", "anonymous": true], "rateLimit": ["kind": NSNull()],
    "models": [], "auto": ["default": "", "levels": []], "defaultModel": "gpt-oss-120b", "widgets": [], "profileDefaults": [:],
    "composer": ["attachments": [["accept": [".txt"], "maxBytes": 1000]], "projectDocuments": [], "pasteAsFileChars": 1000, "dictationMaxSeconds": 60],
    "presets": [], "features": [:],
]

@MainActor
private func makeAccount(
    userId: String?,
    answers: [ScriptedTransport.Answer],
    key: HeldKey? = nil,
    settings: MemoryProfileStorage = MemoryProfileStorage(),
    cloudSync: Bool = true
) -> (account: HarnessAccount, transport: ScriptedTransport) {
    let key = key ?? HeldKey()
    let transport = ScriptedTransport(answers)
    let controlPlane = FreeKeyControlPlane()
    let credentials = HarnessCredentialProvider(
        identity: { _ in userId == nil ? nil : "jwt" },
        chatAccess: ChatAccessCache(controlPlane: controlPlane) { _ in },
        anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
    )
    let client = HarnessClient(credentials: credentials, transport: transport, languages: { ["en"] })
    let account = HarnessAccount(
        userId: userId,
        client: client,
        credentials: credentials,
        keyBytes: { key.bytes },
        settings: settings,
        cloudSync: cloudSync
    )
    return (account, transport)
}

@Suite("Harness account")
@MainActor
struct HarnessAccountTests {
    @Test func settingsReadWithTheHeldKeyNeedNoReloadUntilTheKeyChanges() async throws {
        let key = HeldKey()
        let (account, _) = makeAccount(userId: "user-1", answers: [Answers.json(sessionAnswer), Answers.json(["language": "French"])], key: key)
        #expect(!account.readsHeldKey)
        try await account.refresh()
        #expect(account.keyReady)
        #expect(account.readsHeldKey)
        key.bytes = Data(repeating: 8, count: 32)
        #expect(!account.readsHeldKey)
        key.bytes = Data(repeating: 7, count: 32)
        account.invalidateKey()
        #expect(!account.readsHeldKey)
    }

    @Test func aRefusedKeyIsNotAskedForAgainUntilAnotherIsHeld() async throws {
        let key = HeldKey()
        let (account, _) = makeAccount(userId: "user-1", answers: [Answers.json(sessionAnswer), Answers.refusal(409, code: HarnessErrorCode.keyMismatch, action: "unlock")], key: key)
        try await account.refresh()
        #expect(account.keyLocked)
        #expect(account.readsHeldKey)
        key.bytes = nil
        #expect(!account.readsHeldKey)
    }
}
