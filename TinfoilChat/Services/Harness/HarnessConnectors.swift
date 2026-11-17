import Foundation

private struct ConnectorListing: Decodable {
    var connectors: [Components.Schemas.Connector]
}

/// A connector as the harness answers a change with it, and the page that
/// signs the user in to it while a sign-in the request started is pending.
struct ConnectorAnswer: Decodable, Equatable, Sendable {
    var connector: Components.Schemas.Connector
    var authorizationUrl: String?
}

private struct ConnectorAddRequest: Encodable {
    var name: String
    var url: String
}

private struct ConnectorCompleteRequest: Encodable {
    var id: String
    var code: String
    var state: String
    var iss: String?
}

private struct ConnectorUpdateRequest: Encodable {
    var id: String
    var name: String?
    var enabled: Bool?
    var tools: [String: String]?
}

/// The connectors the harness keeps for an account: the servers it
/// connected, what it signs in to them with, which never leaves the
/// enclave, and what their tools may do in its chats.
@MainActor
enum HarnessConnectors {
    static func list(_ account: HarnessAccount) async throws -> [Components.Schemas.Connector] {
        let listing: ConnectorListing = try await account.post(.connectorsList)
        return listing.connectors
    }

    /// Connects a server. One that asks the user to sign in is added signed
    /// out, with the page that signs them in.
    static func add(_ account: HarnessAccount, name: String, url: String) async throws -> ConnectorAnswer {
        try await account.post(.connectorsAdd, ConnectorAddRequest(name: name, url: url))
    }

    /// Starts a new sign-in to a connector.
    static func authorize(_ account: HarnessAccount, id: String) async throws -> ConnectorAnswer {
        try await account.post(.connectorsAuthorize, ThreadRequest(id: id))
    }

    /// Finishes a sign-in with what the user came back from its page with.
    static func complete(_ account: HarnessAccount, id: String, code: String, state: String, issuer: String?) async throws -> ConnectorAnswer {
        try await account.post(.connectorsComplete, ConnectorCompleteRequest(id: id, code: code, state: state, iss: issuer))
    }

    static func update(_ account: HarnessAccount, id: String, name: String? = nil, enabled: Bool? = nil, tools: [String: ConnectorToolPermission]? = nil) async throws -> ConnectorAnswer {
        try await account.post(.connectorsUpdate, ConnectorUpdateRequest(id: id, name: name, enabled: enabled, tools: tools?.mapValues(\.rawValue)))
    }

    /// Lists the tools a connector's server offers now.
    static func refresh(_ account: HarnessAccount, id: String) async throws -> ConnectorAnswer {
        try await account.post(.connectorsRefresh, ThreadRequest(id: id))
    }

    static func delete(_ account: HarnessAccount, id: String) async throws {
        let _: RawJSON = try await account.post(.connectorsDelete, ThreadRequest(id: id))
    }
}
