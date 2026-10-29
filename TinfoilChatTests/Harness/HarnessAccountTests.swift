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

/// How many times the app was asked to show the sign-in.
private final class SignInPrompts: @unchecked Sendable {
    var count = 0
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
        // An account opened with the key held reads with it before its
        // settings have loaded.
        #expect(account.readsHeldKey)
        try await account.refresh()
        #expect(account.keyReady)
        #expect(account.readsHeldKey)
        key.bytes = Data(repeating: 8, count: 32)
        #expect(!account.readsHeldKey)
        key.bytes = Data(repeating: 7, count: 32)
        account.invalidateKey()
        #expect(!account.readsHeldKey)
    }

    @Test func aKeySetAfterTheAccountOpenedWithoutOneLoadsItAgain() async throws {
        let key = HeldKey()
        key.bytes = nil
        let (account, _) = makeAccount(userId: "user-1", answers: [], key: key)
        #expect(account.readsHeldKey)
        key.bytes = Data(repeating: 7, count: 32)
        #expect(!account.readsHeldKey)
    }

    @Test func aRefusedKeyIsNotAskedForAgainUntilAnotherIsHeld() async throws {
        let key = HeldKey()
        let (account, _) = makeAccount(userId: "user-1", answers: [Answers.json(sessionAnswer), Answers.refusal(409, code: HarnessErrorCode.keyMismatch, action: "unlock")], key: key)
        try await account.refresh()
        #expect(account.keyLocked)
        #expect(!account.profileFailed)
        #expect(account.readsHeldKey)
        key.bytes = nil
        #expect(!account.readsHeldKey)
    }

    @Test func aKeyRefusedWhenTheSettingsAreReadAgainInTheBackgroundIsLocked() async throws {
        let (account, _) = makeAccount(userId: "user-1", answers: [
            Answers.json(sessionAnswer), Answers.json(["language": "French"]),
            Answers.refusal(409, code: HarnessErrorCode.keyMismatch, action: "unlock"),
        ])
        try await account.refresh()
        #expect(account.keyReady)
        await account.refreshProfile(background: true)
        #expect(account.keyLocked)
        #expect(!account.keyReady)
        #expect(account.profile["language"] as? String == "French")
    }

    @Test func settingsTheHarnessRefusesForTheIdentityAskForASignIn() async throws {
        let prompts = SignInPrompts()
        let observer = NotificationCenter.default.addObserver(forName: .chatAuthenticationRequired, object: nil, queue: nil) { _ in prompts.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let refused = Answers.refusal(401, code: HarnessErrorCode.unauthenticated, action: "reauthenticate")
        let (account, _) = makeAccount(userId: "user-1", answers: [Answers.json(sessionAnswer), refused, refused, refused, refused])
        try await account.refresh()
        #expect(prompts.count == 1)
        await #expect(throws: HarnessError.self) { try await account.updateProfile(["language": "French"]) }
        #expect(prompts.count == 2)
    }

    @Test func settingsThisDeviceHoldsShowBeforeTheSessionLoads() async throws {
        let settings = MemoryProfileStorage()
        settings.local = ["language": "French", "reasoningEffort": "high"]
        let (signedOut, transport) = makeAccount(userId: nil, answers: [], settings: settings)
        #expect(signedOut.profileReady)
        #expect(signedOut.keyReady)
        #expect(signedOut.profile["language"] as? String == "French")
        #expect(signedOut.effectiveProfile.reasoningEffort == "high")
        #expect(await transport.requests.isEmpty)

        let (withoutSync, _) = makeAccount(userId: "user-1", answers: [], settings: settings, cloudSync: false)
        #expect(withoutSync.profileReady)
        #expect(!withoutSync.keyReady)
        #expect(withoutSync.profile["language"] as? String == "French")
    }

    @Test func aThemeOrFontThisClientDoesNotKnowLeavesTheOtherSettingsShown() async throws {
        let settings = MemoryProfileStorage()
        settings.local = ["themeMode": "sepia", "chatFont": "handwritten", "reasoningEffort": "high"]
        let (account, _) = makeAccount(userId: nil, answers: [], settings: settings)
        #expect(account.effectiveProfile.reasoningEffort == "high")
        #expect(account.profile["themeMode"] as? String == "sepia")
    }

    @Test func settingsThatFailedForAnotherReasonLoadOnTheNextRefresh() async throws {
        let (account, _) = makeAccount(userId: "user-1", answers: [
            Answers.json(sessionAnswer), Answers.refusal(503, code: "UPSTREAM_UNAVAILABLE", action: "retry"),
            Answers.json(sessionAnswer), Answers.json(["language": "French"]),
        ])
        try await account.refresh()
        #expect(account.profileFailed)
        #expect(!account.keyLocked)
        try await account.refresh(credentials: true)
        #expect(!account.profileFailed)
        #expect(account.profileReady)
        #expect(account.profile["language"] as? String == "French")
    }

    @Test func aSavedPromptIsSentAloneSoPromptsThisDeviceHasNotLoadedStay() async throws {
        var session = sessionAnswer
        session["features"] = ["promptPresetEdits": true]
        let stored: [String: Any] = ["customPromptPresets": [["id": "user:a", "name": "A"], ["id": "user:b", "name": "B"], ["id": "user:c", "name": "C"]]]
        let (account, transport) = makeAccount(userId: "user-1", answers: [
            Answers.json(session), Answers.refusal(503, code: "UPSTREAM_UNAVAILABLE", action: "retry"), Answers.json(stored),
        ])
        try await account.refresh()
        #expect(!account.profileReady)

        try await account.editPrompts(PromptEdits(save: [["id": "user:c", "name": "C"]]))

        let update = try #require(await transport.requests.last)
        #expect(update.route == .profileUpdate)
        let saved = try #require(update.json["savePromptPresets"] as? [[String: Any]])
        #expect(saved.map { $0["id"] as? String } == ["user:c"])
        #expect(update.json["patch"] == nil)
        #expect((account.profile["customPromptPresets"] as? [Any])?.count == 3)
    }

    @Test func aChatServiceWithoutPromptEditsIsSentNoPromptListBeforeTheSettingsLoad() async throws {
        let (account, transport) = makeAccount(userId: "user-1", answers: [
            Answers.json(sessionAnswer), Answers.refusal(503, code: "UPSTREAM_UNAVAILABLE", action: "retry"),
        ])
        try await account.refresh()
        let sent = await transport.requests.count

        await #expect(throws: HarnessError.self) {
            try await account.editPrompts(PromptEdits(save: [["id": "user:c", "name": "C"]]))
        }

        #expect(await transport.requests.count == sent)
        #expect(account.profile["customPromptPresets"] == nil)
    }
}
