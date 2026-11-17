import Combine
import Foundation
import os

/// The account's connectors as the chat service keeps them, and the changes
/// its user makes to them. Settings and the composer show the same list,
/// which is read again when it changes elsewhere: on another device, or as
/// the chat service signs a connector out.
@MainActor
final class ConnectorStore: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Connectors")

    @Published private(set) var connectors: [Connector] = []
    @Published private(set) var isLoading = false
    /// A listing of the account's connectors has finished, so an empty list
    /// means it has none.
    @Published private(set) var listed = false
    @Published private(set) var errorMessage: String?

    private var account: HarnessAccount?
    private let presenter: ConnectorSignInPresenting
    private var watches: Set<AnyCancellable> = []
    /// Only the latest listing applies, so a list read before a change
    /// cannot replace the connector the change answered with.
    private var generation = 0
    /// A change ended a listing before it answered, or was refused: the list
    /// is read again once the change is answered.
    private var listsAgain = false

    init(presenter: ConnectorSignInPresenting = ConnectorSignInSheet()) {
        self.presenter = presenter
    }

    /// Whether the chat service offers connectors to the account: it is
    /// signed in, and its session has the feature.
    var offered: Bool {
        guard let account, account.userId != nil else { return false }
        return account.session?.features.additionalProperties[Constants.Connectors.feature] == true
    }

    /// Whether the account's connectors can be read and changed: the chat
    /// service stores its chats, and its key is unlocked.
    var usable: Bool {
        guard let account, offered else { return false }
        return account.cloud && account.keyReady
    }

    /// The connectors a chat's replies can call: those turned on and signed
    /// in.
    var callable: [Connector] { connectors.filter { $0.enabled && $0.connected } }

    /// Follows an account's connectors, or none once the account is gone.
    func bind(_ account: HarnessAccount?) {
        guard self.account !== account else { return }
        watches.removeAll()
        self.account = account
        clear()
        guard let account else { return }
        account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &watches)
        // The list is read as the account can first be asked for it, and
        // again when its revision changes.
        let offered = account.$session.map { $0?.features.additionalProperties[Constants.Connectors.feature] == true }
        Publishers.CombineLatest4(account.$connectorRevision, account.$keyReady, account.$cloud, offered)
            .map { revision, keyReady, cloud, offered in [revision ?? "", String(keyReady), String(cloud), String(offered)] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &watches)
    }

    private func clear() {
        generation += 1
        listsAgain = false
        connectors = []
        isLoading = false
        listed = false
        errorMessage = nil
    }

    /// Reads the account's connectors again.
    func refresh() async {
        guard let account, usable else { return clear() }
        generation += 1
        listsAgain = false
        let generation = generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let found = try await HarnessConnectors.list(account)
            guard generation == self.generation else { return }
            connectors = found.map { Connector($0) }
            listed = true
            errorMessage = nil
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            Self.logger.error("Failed to list connectors: \(error, privacy: .public)")
            listed = true
            errorMessage = Self.describe(error)
        }
    }

    /// Connects a server, and sends the user to sign in to it when it asks.
    func add(name: String, url: String) async throws {
        guard let account, usable else { return }
        let answer = try await HarnessConnectors.add(account, name: name, url: url)
        guard self.account === account else { return }
        show(answer.connector)
        try await signInIfAsked(answer, account)
    }

    /// Signs in to a connector again.
    func signIn(_ id: String) async throws {
        guard let account, usable else { return }
        let answer = try await HarnessConnectors.authorize(account, id: id)
        guard self.account === account else { return }
        show(answer.connector)
        try await signInIfAsked(answer, account)
    }

    /// Changes whether chats use a connector, or what its tools may do. The
    /// change shows at once, and goes back when the chat service refuses it.
    func update(_ id: String, enabled: Bool? = nil, tools: [String: ConnectorToolPermission]? = nil) async throws {
        guard let account, usable else { return }
        let before = connectors.first { $0.id == id }
        if var changed = before {
            if let enabled { changed.enabled = enabled }
            for index in changed.tools.indices {
                if let permission = tools?[changed.tools[index].name] { changed.tools[index].permission = permission }
            }
            replace(changed)
        }
        do {
            let answer = try await HarnessConnectors.update(account, id: id, enabled: enabled, tools: tools)
            guard self.account === account else { return }
            show(answer.connector)
        } catch {
            // A refused change goes back, and the list is read again, as the
            // connector may no longer be as it was shown.
            if self.account === account {
                if let before { replace(before) }
                listsAgain = true
                listAgainIfAsked()
            }
            throw error
        }
    }

    /// Lists a connector's tools again. One the chat service finds signed
    /// out is listed again, to show that it is.
    func refreshTools(_ id: String) async throws {
        guard let account, usable else { return }
        do {
            let answer = try await HarnessConnectors.refresh(account, id: id)
            guard self.account === account else { return }
            show(answer.connector)
        } catch {
            if (error as? HarnessError)?.code == HarnessErrorCode.connectorSignedOut, self.account === account {
                Task { await refresh() }
            }
            throw error
        }
    }

    func remove(_ id: String) async throws {
        guard let account, usable else { return }
        try await HarnessConnectors.delete(account, id: id)
        guard self.account === account else { return }
        endListing()
        connectors.removeAll { $0.id == id }
        listAgainIfAsked()
    }

    /// Sends the user to the page that signs them in to a connector, when
    /// the chat service names one, and finishes the sign-in with what they
    /// come back with. A user who closes the page leaves the connector
    /// signed out.
    private func signInIfAsked(_ answer: ConnectorAnswer, _ account: HarnessAccount) async throws {
        guard let address = answer.authorizationUrl else { return }
        guard let page = URL(string: address) else {
            throw HarnessError(code: HarnessErrorCode.connectorSignInFailed, message: "The sign-in page has an invalid address.", action: .stop)
        }
        guard let back = try await presenter.signIn(at: page), self.account === account else { return }
        guard back.error == nil, let code = back.code, let state = back.state else {
            throw HarnessError(code: HarnessErrorCode.connectorSignInFailed, message: "The sign-in was canceled or refused.", action: .stop)
        }
        let finished = try await HarnessConnectors.complete(account, id: answer.connector.id, code: code, state: state, issuer: back.issuer)
        guard self.account === account else { return }
        show(finished.connector)
    }

    /// Shows a connector as the chat service answered with it, in place of
    /// the one listed. A listing read meanwhile no longer applies.
    private func show(_ connector: Components.Schemas.Connector) {
        let shown = Connector(connector)
        if connectors.contains(where: { $0.id == shown.id }) {
            replace(shown)
        } else {
            endListing()
            connectors.append(shown)
        }
        listAgainIfAsked()
    }

    private func replace(_ connector: Connector) {
        endListing()
        connectors = connectors.map { $0.id == connector.id ? connector : $0 }
    }

    /// Ends the listing under way, which would show the connectors as they
    /// were before a change made since.
    private func endListing() {
        if isLoading { listsAgain = true }
        generation += 1
        isLoading = false
    }

    /// Reads the list again once the change that asked for it is answered.
    private func listAgainIfAsked() {
        guard listsAgain else { return }
        listsAgain = false
        Task { await refresh() }
    }

    /// What to tell the user about a failed connector request: by the
    /// error's code where it has copy of its own, and otherwise by its
    /// action.
    static func describe(_ error: Error) -> String {
        guard let error = error as? HarnessError else { return "Something went wrong. Try again." }
        switch error.code {
        case HarnessErrorCode.connectorUnreachable:
            return "No MCP server answered at that address. Check the URL and try again."
        case HarnessErrorCode.connectorUnsupported:
            return "This server only works with apps it approved in advance, so it cannot be connected here."
        case HarnessErrorCode.connectorLimit:
            return "You have added the most connectors you can. Remove one to add another."
        case HarnessErrorCode.badRequest:
            return "The chat service could not accept this request."
        case HarnessErrorCode.connectorSignInFailed:
            return error.status == nil ? error.detail.message : "Signing in did not finish. Try signing in again."
        case HarnessErrorCode.connectorSignedOut:
            return "This connector needs you to sign in again."
        case HarnessErrorCode.connectorNotFound:
            return "This connector was removed."
        case HarnessErrorCode.connection:
            return error.detail.message
        default:
            break
        }
        switch error.action {
        case .retry: return "Something went wrong. Try again."
        case .wait: return "Try again later."
        case .unlock: return "Unlock your encryption key in Cloud Sync to manage connectors."
        case .reauthenticate: return "Sign in again to continue."
        case .reload: return "This connector changed. Try again."
        case .revise, .stop: return error.detail.message
        }
    }
}
