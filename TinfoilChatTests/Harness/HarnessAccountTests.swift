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
    /// The key cannot be read, as while the device is locked.
    var unreadable = false
}

/// How many times the app was asked to show the sign-in.
private final class SignInPrompts: @unchecked Sendable {
    var count = 0
}

private let sessionAnswer: [String: Any] = [
    "protocol": ["version": 1, "minimum": 1], "user": ["id": "", "anonymous": true], "rateLimit": ["kind": NSNull()],
    "models": [], "auto": ["default": "", "levels": []], "defaultModel": "gpt-oss-120b", "widgets": [], "profileDefaults": [:],
    "composer": ["attachments": [["accept": [".txt"], "maxBytes": 1000]], "projectDocuments": [], "pasteAsFileChars": 1000, "dictationMaxSeconds": 60, "dictationSegmentSeconds": 30],
    "presets": [], "features": [:],
]

@MainActor
private func makeAccount(
    userId: String?,
    answers: [ScriptedTransport.Answer],
    key: HeldKey? = nil,
    settings: MemoryProfileStorage = MemoryProfileStorage(),
    cloudSync: Bool = true,
    sessionEnded: Bool = false
) -> (account: HarnessAccount, transport: ScriptedTransport) {
    let key = key ?? HeldKey()
    let transport = ScriptedTransport(answers)
    let controlPlane = FreeKeyControlPlane()
    // An account whose session ended still holds the token last issued, and
    // is issued no other.
    let credentials = HarnessCredentialProvider(
        identity: { refresh in userId == nil || (refresh && sessionEnded) ? nil : "jwt" },
        chatAccess: ChatAccessCache(controlPlane: controlPlane) { _ in },
        anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
    )
    let client = HarnessClient(credentials: credentials, transport: transport, languages: { ["en"] })
    let account = HarnessAccount(
        userId: userId,
        client: client,
        credentials: credentials,
        keyBytes: {
            if key.unreadable { throw KeychainError.unavailable }
            return key.bytes
        },
        settings: settings,
        cloudSync: cloudSync
    )
    return (account, transport)
}

@Suite("Harness account")
@MainActor
struct HarnessAccountTests {
    @Test func remoteImagesUseTheHarnessBodyAndNeedNoContentKey() async throws {
        let bytes = Data([1, 2, 3])
        let (account, transport) = makeAccount(userId: "user-1", answers: [Answers.json([
            "image_bytes": bytes.base64EncodedString(), "image_content_type": "image/png",
        ])], cloudSync: false)
        let imageURL = "https://images.example/private-token.png"
        let result = try await HarnessMetadata.image(account, url: imageURL)
        #expect(result == bytes)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.route == .remoteImage)
        #expect(request.json["url"] as? String == imageURL)
        #expect(request.json["key"] == nil)
        #expect(!request.headers.values.contains { $0.contains(imageURL) })
        account.dispose()
    }

    @Test func aDocumentThatReplacesAnotherNamesItBeforeItsFile() async throws {
        var session = sessionAnswer
        var composer = try #require(session["composer"] as? [String: Any])
        composer["projectDocuments"] = [["accept": [".txt"], "maxBytes": 1000]]
        session["composer"] = composer
        let stored: [String: Any] = [
            "id": "doc-1", "projectId": "project-1", "filename": "notes.txt", "contentType": "text/plain", "sizeBytes": 5, "hasFile": true,
        ]
        let (account, transport) = makeAccount(userId: "user-1", answers: [Answers.json(session), Answers.json(stored)])

        let document = try await HarnessProjects.uploadDocument(
            account, projectId: "project-1", replacing: "doc-1", file: Data("Notes".utf8), fileName: "notes.txt", mimeType: "text/plain"
        )

        #expect(document.id == "doc-1")
        #expect(ProjectDocument(document).hasFile)
        let upload = try #require(await transport.requests.last)
        #expect(upload.route == .projectDocumentUpload)
        let form = String(decoding: upload.body, as: UTF8.self)
        let file = try #require(form.range(of: "name=\"file\""))
        for field in ["documentId", "key", "projectId"] {
            let named = try #require(form.range(of: "name=\"\(field)\""))
            #expect(named.upperBound < file.lowerBound)
        }
        #expect(form.contains("name=\"documentId\"\r\n\r\ndoc-1\r\n"))
        #expect(form.contains("name=\"projectId\"\r\n\r\nproject-1\r\n"))
        account.dispose()
    }

    @Test func aNewDocumentNamesNoDocumentToReplace() async throws {
        var session = sessionAnswer
        var composer = try #require(session["composer"] as? [String: Any])
        composer["projectDocuments"] = [["accept": [".txt"], "maxBytes": 1000]]
        session["composer"] = composer
        let stored: [String: Any] = [
            "id": "doc-2", "projectId": "project-1", "filename": "notes.txt", "contentType": "text/plain", "sizeBytes": 5,
        ]
        let (account, transport) = makeAccount(userId: "user-1", answers: [Answers.json(session), Answers.json(stored)])

        let document = try await HarnessProjects.uploadDocument(
            account, projectId: "project-1", file: Data("Notes".utf8), fileName: "notes.txt", mimeType: "text/plain"
        )

        #expect(!ProjectDocument(document).hasFile)
        let upload = try #require(await transport.requests.last)
        #expect(!String(decoding: upload.body, as: UTF8.self).contains("documentId"))
        account.dispose()
    }

    @Test func aDocumentsFileIsDownloadedWithTheContentKey() async throws {
        let file = Data([1, 2, 3])
        let (account, transport) = makeAccount(userId: "user-1", answers: [{ _ in
            HarnessResponse.collected(status: 200, headers: ["content-type": "application/octet-stream"], sealed: true, body: file)
        }])

        let downloaded = try await HarnessProjects.downloadDocument(account, projectId: "project-1", documentId: "doc-1")

        #expect(downloaded == file)
        let request = try #require(await transport.requests.first)
        #expect(request.route == .projectDocumentDownload)
        #expect(request.json["projectId"] as? String == "project-1")
        #expect(request.json["documentId"] as? String == "doc-1")
        #expect(request.json["key"] as? String == Data(repeating: 7, count: 32).base64EncodedString())
        account.dispose()
    }

    @Test func artifactsAreListedByProjectAndCursorWithTheContentKey() async throws {
        let listed: [String: Any] = [
            "artifacts": [[
                "threadId": "thread-1", "threadTitle": "Plans", "projectId": NSNull(), "messageId": "msg-1", "toolCallId": "call-1",
                "title": "", "sourceType": "slides", "createdAt": "2026-01-01T00:00:00Z",
            ]],
            "nextCursor": "c2",
        ]
        let (account, transport) = makeAccount(userId: "user-1", answers: [
            Answers.json(listed), Answers.json(["artifacts": [], "nextCursor": ""]),
        ])

        let page = try await HarnessArtifacts.list(account, projectId: "project-1", cursor: "c1")

        #expect(page.nextCursor == "c2")
        let artifact = try #require(page.artifacts.first)
        #expect(artifact.projectId == nil)
        // A kind a later harness adds shows as a generic artifact.
        #expect(artifact.kind == nil)
        #expect(artifact.sourceType.value2 == "slides")
        let request = try #require(await transport.requests.first)
        #expect(request.route == .artifactsList)
        #expect(request.json["projectId"] as? String == "project-1")
        #expect(request.json["cursor"] as? String == "c1")
        #expect(request.json["key"] as? String == Data(repeating: 7, count: 32).base64EncodedString())

        // The first page of every chat's artifacts names neither.
        let all = try await HarnessArtifacts.list(account)
        #expect(all.artifacts.isEmpty)
        let first = try #require(await transport.requests.last)
        #expect(first.json["projectId"] == nil)
        #expect(first.json["cursor"] == nil)
        account.dispose()
    }

    @Test func anArtifactOpensByItsChatReplyAndCallWithTheArgumentsItsWidgetReads() async throws {
        let stored: [String: Any] = [
            "threadId": "thread-1", "threadTitle": "Plans", "projectId": "project-1", "messageId": "msg-1", "toolCallId": "call-1",
            "title": "Plan", "sourceType": "markdown", "createdAt": "2026-01-01T00:00:00Z",
        ]
        let arguments = #"{"title":"Plan","source":{"type":"markdown","markdown":"# Plan"}}"#
        let (account, transport) = makeAccount(userId: "user-1", answers: [Answers.json(["artifact": stored, "arguments": arguments])])
        let listed = try JSONDecoder().decode(ListedArtifact.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(listed.kind == .markdown)

        let opened = try await HarnessArtifacts.get(account, listed)

        #expect(opened.artifact == listed)
        let args = try JSONDecoder().decode(ArtifactPreviewWidget.Args.self, from: Data(opened.arguments.utf8))
        #expect(args.title == "Plan")
        #expect(args.source.type == .markdown)
        #expect(args.source.markdown == "# Plan")
        let request = try #require(await transport.requests.first)
        #expect(request.route == .artifactGet)
        #expect(request.json["threadId"] as? String == "thread-1")
        #expect(request.json["messageId"] as? String == "msg-1")
        #expect(request.json["toolCallId"] as? String == "call-1")
        #expect(request.json["key"] as? String == Data(repeating: 7, count: 32).base64EncodedString())
        account.dispose()
    }

    @Test func malformedRemoteImagesAreRefused() async throws {
        let (account, transport) = makeAccount(userId: nil, answers: [Answers.json([
            "image_bytes": "not-base64", "image_content_type": "image/png",
        ])], cloudSync: false)
        await #expect(throws: LinkMetadataError.self) {
            try await HarnessMetadata.image(account, url: "https://images.example/photo.png")
        }
        #expect(await transport.requests.count == 1)
        account.dispose()
    }

    @Test func aCanceledImageWaiterStillWarmsItsAccountsCache() async throws {
        let bytes = Data([1, 2, 3])
        let (account, transport) = makeAccount(userId: nil, answers: [Answers.json([
            "image_bytes": bytes.base64EncodedString(), "image_content_type": "image/png",
        ])], cloudSync: false)
        let service = LinkMetadataService()
        await service.bind(account)
        await transport.hold()
        let pending = Task { try await service.image(for: "https://images.example/photo.png") }
        await transport.arrived()
        pending.cancel()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await service.image(for: "https://images.example/photo.png") == bytes)
        #expect(await transport.requests.count == 1)
        account.dispose()
    }

    @Test func anImageFromAnOldAccountCannotReplaceTheNewAccountsCache() async throws {
        let original = Data([1, 2, 3])
        let replacement = Data([4, 5, 6])
        let (first, firstTransport) = makeAccount(userId: nil, answers: [Answers.json([
            "image_bytes": original.base64EncodedString(), "image_content_type": "image/png",
        ])], cloudSync: false)
        let (second, secondTransport) = makeAccount(userId: nil, answers: [Answers.json([
            "image_bytes": replacement.base64EncodedString(), "image_content_type": "image/png",
        ])], cloudSync: false)
        let service = LinkMetadataService()
        await service.bind(first)
        await firstTransport.hold()
        let pending = Task { try await service.image(for: "https://images.example/photo.png") }
        await firstTransport.arrived()
        await service.bind(second)
        #expect(try await service.image(for: "https://images.example/photo.png") == replacement)
        await firstTransport.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await service.image(for: "https://images.example/photo.png") == replacement)
        #expect(await secondTransport.requests.count == 1)
        first.dispose()
        second.dispose()
    }

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

    @Test func aKeyTheLockedDeviceCannotReadIsNotTakenForAMissingOne() async throws {
        let key = HeldKey()
        key.unreadable = true
        let (account, _) = makeAccount(userId: "user-1", answers: [
            Answers.json(sessionAnswer),
            Answers.json(sessionAnswer), Answers.json(["language": "French"]),
        ], key: key)
        try await account.refresh()
        #expect(!account.keyLocked)
        #expect(account.profileFailed)
        key.unreadable = false
        try await account.refresh(credentials: true)
        #expect(!account.profileFailed)
        #expect(account.keyReady)
        #expect(account.profile["language"] as? String == "French")
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

    @Test func aFailedCheckForChangesKeepsTheLastSyncUntilACheckSucceeds() async throws {
        let tokens: [String: Any] = ["chats": "c1", "profile": "p1", "projects": "j1"]
        let (account, _) = makeAccount(userId: "user-1", answers: [
            Answers.json(sessionAnswer), Answers.json([:]),
            Answers.json(tokens), Answers.json([:]),
            Answers.refusal(503, code: "UPSTREAM_UNAVAILABLE", action: "retry"),
            Answers.json(tokens),
        ])
        try await account.refresh()
        #expect(account.syncStatus.lastSyncedAt == nil)

        await account.checkChanges()
        let synced = try #require(account.syncStatus.lastSyncedAt)
        #expect(!account.syncStatus.failing)

        await account.checkChanges()
        #expect(account.syncStatus.failing)
        #expect(account.syncStatus.lastSyncedAt == synced)

        await account.checkChanges()
        #expect(!account.syncStatus.failing)
        #expect(try #require(account.syncStatus.lastSyncedAt) > synced)

        account.invalidateKey()
        #expect(account.syncStatus.lastSyncedAt == nil)
    }

    @Test func settingsTheHarnessRefusesAnAccountWhoseSessionEndedAskForASignIn() async throws {
        let prompts = SignInPrompts()
        let observer = NotificationCenter.default.addObserver(forName: .chatAuthenticationRequired, object: nil, queue: nil) { _ in prompts.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let refused = Answers.refusal(401, code: HarnessErrorCode.unauthenticated, action: "reauthenticate")
        let (account, _) = makeAccount(userId: "user-1", answers: [Answers.json(sessionAnswer), refused, refused], sessionEnded: true)
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

    @Test func theModelsTheLastSessionOfferedShowUntilTheSessionLoadsWhichKeepsItsOwn() async throws {
        let settings = MemoryProfileStorage()
        settings.keptModels = [Components.Schemas.SessionModel(id: "kimi-k3", label: "Kimi K3", shortLabel: "Kimi", icon: "moonshot.png", description: "", badges: [], deprecated: false)]
        var opened = sessionAnswer
        opened["models"] = [
            ["id": "auto", "label": "Auto", "shortLabel": "Auto", "icon": "", "description": "", "badges": [], "reasoning": NSNull(), "deprecated": false, "auto": true],
            ["id": "gpt-oss-120b", "label": "GPT-OSS 120B", "shortLabel": "GPT-OSS", "icon": "openai.png", "description": "", "badges": [], "reasoning": NSNull(), "deprecated": false],
        ]
        let (account, _) = makeAccount(userId: nil, answers: [Answers.json(opened)], settings: settings)
        #expect(account.models.map(\.id) == ["kimi-k3"])

        try await account.refresh()

        #expect(account.models.map(\.id) == ["auto", "gpt-oss-120b"])
        #expect(settings.keptModels == account.session?.models)
    }

    @Test func aQuotaOfAKindThisClientDoesNotKnowClearsADailyQuotaButLeavesAnHourlyBudget() async throws {
        let (account, _) = makeAccount(userId: nil, answers: [])
        let monthly = try JSONDecoder().decode(HarnessRateLimit.self, from: Data(#"{"kind":"monthly","maxRequests":100,"remaining":50}"#.utf8))

        account.reportRateLimit(HarnessRateLimit(kind: .named(.freeDaily), maxRequests: 20, remaining: 3))
        account.reportRateLimit(monthly)
        #expect(account.rateLimit.flatMap(RateLimitInfo.init) == nil)

        let hourly = HarnessRateLimit(kind: .named(.hourly), inputTokens: .init(max: 2_000_000, used: 500_000, remaining: 1_500_000))
        account.reportMintedRateLimit(hourly)
        account.reportRateLimit(monthly)
        #expect(account.rateLimit == hourly)
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

    @Test(arguments: [true, false])
    func aChangedPromptIsSentAsTheChangeOrWholeAsThisDeviceHasIt(updates: Bool) async throws {
        var session = sessionAnswer
        session["features"] = ["promptPresetEdits": true, "promptPresetUpdates": updates]
        let preset: [String: Any] = ["id": "user:a", "name": "A", "model": "kimi-k3", "webSearchEnabled": false]
        var renamed = preset
        renamed["name"] = "A2"
        let (account, transport) = makeAccount(userId: "user-1", answers: [
            Answers.json(session), Answers.json(["customPromptPresets": [preset]]), Answers.json(["customPromptPresets": [renamed]]),
        ])
        try await account.refresh()

        try await account.editPrompts(PromptEdits(update: [["id": "user:a", "name": "A2"]]))

        let update = try #require(await transport.requests.last)
        #expect(update.route == .profileUpdate)
        if updates {
            // Only what changed, so what another device saved since stays.
            let sent = try #require(update.json["updatePromptPresets"] as? [[String: Any]])
            #expect(sent.count == 1)
            #expect(NSDictionary(dictionary: sent[0]) == NSDictionary(dictionary: ["id": "user:a", "name": "A2"]))
            #expect(update.json["savePromptPresets"] == nil)
        } else {
            let sent = try #require(update.json["savePromptPresets"] as? [[String: Any]])
            #expect(sent.count == 1)
            #expect(NSDictionary(dictionary: sent[0]) == NSDictionary(dictionary: ["id": "user:a", "name": "A2", "model": "kimi-k3", "webSearchEnabled": false]))
            #expect(update.json["updatePromptPresets"] == nil)
        }
        let shown = try #require((account.profile["customPromptPresets"] as? [[String: Any]])?.first)
        #expect(NSDictionary(dictionary: shown) == NSDictionary(dictionary: renamed))
    }

    @Test func aSignedOutCallersSettingsFromThePreviousAppUpgradeAsTheProfileTheHarnessAnswers() async throws {
        let settings = MemoryProfileStorage()
        settings.local = ["language": "Français", "customPromptPresets": [["id": "user:a", "name": "A"]]]
        let upgraded: [String: Any] = ["language": "French", "customPromptPresets": [["id": "user:a", "name": "A", "systemPrompt": ""]]]
        let (account, _) = makeAccount(userId: nil, answers: [Answers.json(sessionAnswer), Answers.json(["profile": upgraded])], settings: settings)

        try await account.refresh()

        #expect(settings.localProfileUpgraded)
        #expect(settings.local["profile"] == nil)
        #expect(settings.local["language"] as? String == "French")
        #expect((settings.local["customPromptPresets"] as? [Any])?.count == 1)
        #expect(account.profile["language"] as? String == "French")
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
