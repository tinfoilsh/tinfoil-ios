//
//  ConnectorModels.swift
//  TinfoilChat
//
//  Connectors as the views show them, from what the chat service stores.
//

import Foundation

/// What a connector's tool may do in a chat.
enum ConnectorToolPermission: String, CaseIterable, Identifiable, Sendable {
    case allow
    case ask
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allow: return "Always allow"
        case .ask: return "Ask first"
        case .off: return "Off"
        }
    }

    /// A permission this client does not know shows as ask.
    init(_ permission: Components.Schemas.ToolPermission) {
        switch permission.value1 {
        case .allow: self = .allow
        case .off: self = .off
        case .ask, nil: self = .ask
        }
    }
}

/// A tool a connector's server offers.
struct ConnectorTool: Identifiable, Equatable, Sendable {
    let name: String
    var title: String?
    var summary: String?
    /// The server says the tool changes nothing.
    var readOnly: Bool
    var permission: ConnectorToolPermission

    var id: String { name }
    var displayName: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? name }

    init(_ tool: Components.Schemas.Connector.ToolsPayloadPayload) {
        name = tool.name
        title = tool.title
        summary = tool.description
        readOnly = tool.readOnly ?? false
        permission = ConnectorToolPermission(tool.permission)
    }
}

/// A server the account connected, whose tools its chats' replies can call.
struct Connector: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var url: String
    /// Whether chats call its tools.
    var enabled: Bool
    /// Its tools can be called. Otherwise the user must sign in first, which
    /// is also how a status this client does not know shows.
    var connected: Bool
    /// The server asks the user to sign in.
    var signIn: Bool
    var tools: [ConnectorTool]

    /// The server's host, which tells connectors of the same name apart.
    var host: String { URL(string: url)?.host ?? url }

    init(_ connector: Components.Schemas.Connector) {
        id = connector.id
        name = connector.name
        url = connector.url
        enabled = connector.enabled
        connected = connector.status.value1 == .connected
        signIn = connector.signIn
        tools = connector.tools.map(ConnectorTool.init)
    }
}

/// A server the app lists for the user to connect.
struct ConnectorCatalogEntry: Identifiable, Equatable, Decodable, Sendable {
    let id: String
    let name: String
    let url: String
    let vendor: String
    let website: String
    let categories: [String]

    /// Whether the entry answers a search, by its name, vendor or category.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([name, vendor] + categories).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The servers the app lists, which need no sign-in or sign the chat
/// service in without an account made with them in advance.
enum ConnectorCatalog {
    static func load() throws -> [ConnectorCatalogEntry] {
        guard let file = Bundle.main.url(forResource: Constants.Connectors.catalogResource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([ConnectorCatalogEntry].self, from: Data(contentsOf: file))
    }
}

/// A call a reply makes to a connector's tool, as the chat shows it.
struct ConnectorCallState: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running
        case completed
        case failed
    }

    /// The user's answer to a call that needs it.
    enum Approval: Equatable, Sendable {
        /// The call waits for the user's answer under this id, until then.
        case pending(id: String, expiresAt: Date?)
        case approved
        case declined
        case expired
    }

    let id: String
    var connectorId: String
    var connectorName: String
    var connectorURL: String
    /// The tool as its server names it.
    var tool: String
    var title: String?
    var status: Status
    var approval: Approval?
    var startedAt: Double?
    var endedAt: Double?

    var toolName: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? tool }

    /// The id the user's answer names, while the call still waits for it.
    func pendingApprovalId(now: Date = Date()) -> String? {
        guard status == .running, case .pending(let id, let expiresAt) = approval else { return nil }
        if let expiresAt, expiresAt <= now { return nil }
        return id
    }
}

/// How the user answers a call that waits for their approval.
enum ConnectorApprovalChoice: Equatable, Sendable {
    /// Lets this call run.
    case once
    /// Lets this call run, and its tool without asking from then on.
    case always
    case decline
}

/// What a call's approval shows of the user's answer while it is sent.
struct ConnectorApprovalState: Equatable, Sendable {
    /// The answer being sent.
    var sending: ConnectorApprovalChoice?
    /// The answer was sent: the reply's stream shows how the call went.
    var answered = false
    /// Why the answer could not be sent.
    var error: String?
}
