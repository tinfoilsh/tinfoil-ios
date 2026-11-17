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

/// A sign-in page that answers at once with what the test scripts, and keeps
/// the pages it was asked to open.
@MainActor
private final class ScriptedSignIn: ConnectorSignInPresenting {
    private(set) var pages: [URL] = []
    /// What the test does as a page opens.
    var onOpen: (() -> Void)?
    private let answer: ConnectorSignInAnswer?

    init(answer: ConnectorSignInAnswer?) {
        self.answer = answer
    }

    func signIn(at page: URL) async throws -> ConnectorSignInAnswer? {
        pages.append(page)
        onOpen?()
        return answer
    }
}

/// The session the chat service opens for a signed-in account it offers
/// connectors to.
private let connectorsSession: [String: Any] = [
    "protocol": ["version": 1, "minimum": 1], "user": ["id": "user-1", "anonymous": false], "rateLimit": ["kind": NSNull()],
    "models": [], "auto": ["default": "", "levels": []], "defaultModel": "gpt-oss-120b", "widgets": [], "profileDefaults": [:],
    "composer": ["attachments": [], "projectDocuments": [], "pasteAsFileChars": 1000, "dictationMaxSeconds": 60, "dictationSegmentSeconds": 30],
    "presets": [], "features": ["connectors": true],
]

private let serverURL = "https://mcp.example.test/mcp"

/// The page the chat service names to sign in to a connector's server.
private let signInPage = "https://auth.example.test/authorize?client_id=tinfoil&redirect_uri=https%3A%2F%2Fchat.tinfoil.sh%2Fconnectors%2Fcallback&state=state-1"

/// A connector as the chat service answers with it.
private func connector(_ id: String, enabled: Bool = true, status: String = "connected", tools: [[String: Any]] = []) -> [String: Any] {
    ["id": id, "name": "Fake", "url": serverURL, "enabled": enabled, "status": status, "signIn": true,
     "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "tools": tools]
}

/// Waits for a store to show what a request it sends on its own brings.
@MainActor
private func eventually(_ shown: () -> Bool) async throws {
    var waited = 0
    while !shown(), waited < 100 {
        try await Task.sleep(for: .milliseconds(10))
        waited += 1
    }
}

@MainActor
private struct Fixture {
    let transport: ScriptedTransport
    let account: HarnessAccount
    let presenter: ScriptedSignIn
    let store: ConnectorStore

    /// A signed-in account whose key is held, and a store of its connectors
    /// whose sign-ins a scripted page answers.
    init(answers: [ScriptedTransport.Answer], cloudSync: Bool = true, signIn: ConnectorSignInAnswer? = nil) {
        transport = ScriptedTransport(answers)
        let controlPlane = FreeKeyControlPlane()
        let credentials = HarnessCredentialProvider(
            identity: { _ in "jwt" },
            chatAccess: ChatAccessCache(controlPlane: controlPlane) { _ in },
            anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
        )
        let client = HarnessClient(credentials: credentials, transport: transport, languages: { ["en"] })
        account = HarnessAccount(
            userId: "user-1",
            client: client,
            credentials: credentials,
            keyBytes: { Data(repeating: 7, count: 32) },
            settings: MemoryProfileStorage(),
            cloudSync: cloudSync
        )
        presenter = ScriptedSignIn(answer: signIn)
        store = ConnectorStore(presenter: presenter)
    }

    /// An account with cloud sync, open on a chat service that offers
    /// connectors, and a store that listed the connectors given as it was
    /// bound to the account.
    static func listing(_ connectors: [[String: Any]], signIn: ConnectorSignInAnswer? = nil) async throws -> Fixture {
        let fixture = Fixture(
            answers: [Answers.json(connectorsSession), Answers.json([:]), Answers.json(["connectors": connectors])],
            signIn: signIn
        )
        try await fixture.account.refresh()
        // The account's session and key have loaded, so the store reads the
        // list once as it is bound.
        fixture.store.bind(fixture.account)
        try await eventually { fixture.store.listed }
        try #require(fixture.store.listed)
        return fixture
    }
}

@Suite("Connector store")
@MainActor
struct ConnectorStoreTests {
    /// Why a change the store was asked for failed, if it did.
    private func failure(_ change: () async throws -> Void) async -> HarnessError? {
        do {
            try await change()
            return nil
        } catch {
            return error as? HarnessError
        }
    }

    @Test func theAccountsConnectorsAreListedWithWhichOfThemChatsCanCall() async throws {
        let tools: [[String: Any]] = [
            ["name": "search_pages", "title": "Search pages", "readOnly": true, "permission": "allow"],
            ["name": "create_page", "permission": "sometimes"],
        ]
        let fixture = try await Fixture.listing([
            connector("a", tools: tools), connector("b", status: "signedOut"), connector("c", status: "paused"), connector("d", enabled: false),
        ])
        let store = fixture.store
        #expect(store.connectors.map(\.id) == ["a", "b", "c", "d"])
        // A status this client does not know shows as signed out.
        #expect(store.connectors.map(\.connected) == [true, false, false, true])
        #expect(store.callable.map(\.id) == ["a"])
        // A permission this client does not know shows as ask.
        #expect(store.connectors.first?.tools.map(\.permission) == [.allow, .ask])
        #expect(store.connectors.first?.tools.map(\.displayName) == ["Search pages", "create_page"])
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
        let listing = try #require(await fixture.transport.requests.last)
        #expect(listing.route == .connectorsList)
        #expect(listing.json["key"] as? String == Data(repeating: 7, count: 32).base64EncodedString())

        // Read again, the list shows a connector the chat service signed out.
        await fixture.transport.push(Answers.json(["connectors": [connector("a", status: "signedOut")]]))
        await store.refresh()
        #expect(store.connectors.map(\.id) == ["a"])
        #expect(store.callable.isEmpty)
        #expect(await fixture.transport.requests.map(\.route) == [.session, .profileGet, .connectorsList, .connectorsList])
    }

    @Test func aServerThatAsksForASignInIsConnectedOnceTheUserComesBackFromItsPage() async throws {
        let back = ConnectorSignInAnswer(code: "code-1", state: "state-1", issuer: "https://auth.example.test")
        let fixture = try await Fixture.listing([], signIn: back)
        let store = fixture.store
        await fixture.transport.push(Answers.json(["connector": connector("c1", status: "signedOut"), "authorizationUrl": signInPage]))
        await fixture.transport.push(Answers.json(["connector": connector("c1", tools: [["name": "create_page", "permission": "ask"]])]))
        var shownAtThePage: [Connector] = []
        fixture.presenter.onOpen = { shownAtThePage = store.connectors }

        try await store.add(name: "Fake", url: serverURL)

        #expect(fixture.presenter.pages.map(\.absoluteString) == [signInPage])
        // The connector is listed signed out until its sign-in finishes.
        #expect(shownAtThePage.map(\.id) == ["c1"])
        #expect(shownAtThePage.map(\.connected) == [false])
        #expect(store.connectors.map(\.id) == ["c1"])
        #expect(store.connectors.map(\.connected) == [true])
        #expect(store.connectors.first?.tools.map(\.name) == ["create_page"])
        let requests = await fixture.transport.requests
        #expect(requests.map(\.route) == [.session, .profileGet, .connectorsList, .connectorsAdd, .connectorsComplete])
        let added = try #require(requests.dropLast().last)
        #expect(added.json["name"] as? String == "Fake")
        #expect(added.json["url"] as? String == serverURL)
        // The chat service finishes the sign-in with what the page answered.
        let completed = try #require(requests.last)
        #expect(completed.json["id"] as? String == "c1")
        #expect(completed.json["code"] as? String == "code-1")
        #expect(completed.json["state"] as? String == "state-1")
        #expect(completed.json["iss"] as? String == "https://auth.example.test")
        #expect(completed.json["key"] as? String == Data(repeating: 7, count: 32).base64EncodedString())
    }

    @Test func aUserWhoClosesTheSignInPageLeavesTheConnectorSignedOut() async throws {
        let fixture = try await Fixture.listing([])
        await fixture.transport.push(Answers.json(["connector": connector("c1", status: "signedOut"), "authorizationUrl": signInPage]))

        try await fixture.store.add(name: "Fake", url: serverURL)

        #expect(fixture.presenter.pages.count == 1)
        #expect(fixture.store.connectors.map(\.id) == ["c1"])
        #expect(fixture.store.connectors.map(\.connected) == [false])
        #expect(await fixture.transport.requests.map(\.route) == [.session, .profileGet, .connectorsList, .connectorsAdd])
    }

    @Test func aSignInTheAuthorizationServerRefusedFailsAndFinishesNothing() async throws {
        let fixture = try await Fixture.listing([], signIn: ConnectorSignInAnswer(state: "state-1", error: "access_denied"))
        await fixture.transport.push(Answers.json(["connector": connector("c1", status: "signedOut"), "authorizationUrl": signInPage]))

        let refused = await failure { try await fixture.store.add(name: "Fake", url: serverURL) }

        #expect(refused?.code == HarnessErrorCode.connectorSignInFailed)
        #expect(fixture.presenter.pages.count == 1)
        #expect(fixture.store.connectors.map(\.connected) == [false])
        #expect(await fixture.transport.requests.map(\.route) == [.session, .profileGet, .connectorsList, .connectorsAdd])
    }

    @Test func aChangeShowsAtOnceAndGoesBackWhenTheChatServiceRefusesIt() async throws {
        let fixture = try await Fixture.listing([connector("c1", tools: [["name": "create_page", "permission": "ask"]])])
        let store = fixture.store
        await fixture.transport.push(Answers.refusal(409, code: HarnessErrorCode.revisionConflict, action: "reload"))
        await fixture.transport.hold()
        let changing = Task { try await store.update("c1", enabled: false, tools: ["create_page": .allow]) }
        await fixture.transport.arrived()

        #expect(store.connectors.first?.enabled == false)
        #expect(store.connectors.first?.tools.map(\.permission) == [.allow])
        await fixture.transport.release()
        await #expect(throws: HarnessError.self) { try await changing.value }

        #expect(store.connectors.first?.enabled == true)
        #expect(store.connectors.first?.tools.map(\.permission) == [.ask])
        let update = try #require(await fixture.transport.requests.last)
        #expect(update.route == .connectorsUpdate)
        #expect(update.json["id"] as? String == "c1")
        #expect(update.json["enabled"] as? Bool == false)
        #expect(update.json["tools"] as? [String: String] == ["create_page": "allow"])
    }

    @Test func aConnectorFoundSignedOutAsItsToolsAreListedAgainIsListedAgain() async throws {
        let fixture = try await Fixture.listing([connector("c1")])
        let store = fixture.store
        await fixture.transport.push(Answers.refusal(409, code: HarnessErrorCode.connectorSignedOut, action: "stop"))
        await fixture.transport.push(Answers.json(["connectors": [connector("c1", status: "signedOut")]]))

        let refused = await failure { try await store.refreshTools("c1") }

        #expect(refused?.code == HarnessErrorCode.connectorSignedOut)
        try await eventually { store.connectors.first?.connected == false }
        #expect(store.connectors.map(\.connected) == [false])
        let requests = await fixture.transport.requests
        #expect(requests.map(\.route) == [.session, .profileGet, .connectorsList, .connectorsRefresh, .connectorsList])
        #expect(requests.dropLast().last?.json["id"] as? String == "c1")
    }

    @Test func anAccountWhoseChatsStayOnThisDeviceIsAskedForNoConnectors() async throws {
        let fixture = Fixture(answers: [Answers.json(connectorsSession)], cloudSync: false)
        try await fixture.account.refresh()
        let store = fixture.store
        store.bind(fixture.account)
        #expect(store.offered)
        #expect(!store.usable)

        await store.refresh()
        try await store.add(name: "Fake", url: serverURL)

        #expect(!store.listed)
        #expect(store.connectors.isEmpty)
        #expect(fixture.presenter.pages.isEmpty)
        #expect(await fixture.transport.requests.map(\.route) == [.session])
    }
}
