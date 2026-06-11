//
//  SyncEnclaveClient.swift
//  TinfoilChat
//
//  Singleton wrapper around the TinfoilAI SDK's SecureClient pointed
//  at the sync enclave. The enclave is the only encryptor; the
//  controlplane only ever sees ciphertext from the enclave's
//  perspective.
//
//  Callers should:
//    1. await `SyncEnclaveClient.shared.ready()` to ensure attestation.
//    2. call `client.post(path:body:)` / `client.get(path:)` to make
//       attested JSON-RPC requests with the user's Clerk JWT injected.
//

import ClerkKit
import Foundation
import TinfoilAI

/// Error envelope returned by the sync enclave, parsed from `{error, code, ...details}`.
struct SyncEnclaveError: LocalizedError, Equatable {
    let message: String
    let status: Int?
    let code: String?
    let details: [String: AnyCodable]?

    var errorDescription: String? { message }

    static func == (lhs: SyncEnclaveError, rhs: SyncEnclaveError) -> Bool {
        lhs.message == rhs.message && lhs.status == rhs.status && lhs.code == rhs.code
    }

    init(message: String, status: Int? = nil, code: String? = nil, details: [String: AnyCodable]? = nil) {
        self.message = message
        self.status = status
        self.code = code
        self.details = details
    }

    static let authenticationRequired = SyncEnclaveError(
        message: "Authentication required for sync enclave",
        status: 401,
        code: WireCodes.auth
    )

    static let invalidEnclaveURL = SyncEnclaveError(
        message: "Sync enclave URL must be an absolute HTTPS URL",
        code: "INVALID_SYNC_ENCLAVE_URL"
    )

    static let invalidPath = SyncEnclaveError(
        message: "Sync enclave request path must be relative",
        code: "INVALID_SYNC_ENCLAVE_PATH"
    )
}

/// Singleton attested client for the sync enclave. Verification runs once
/// per app launch (lazy); concurrent callers share the in-flight task.
actor SyncEnclaveClient {
    static let shared = SyncEnclaveClient()

    private let enclaveURL: String
    private let configRepo: String
    private var client: SecureClient?
    private var verificationTask: Task<SecureClient, Error>?
    private var tokenGetter: (@Sendable () async -> String?)?

    init(
        enclaveURL: String = Constants.SyncEnclave.url,
        configRepo: String = Constants.SyncEnclave.configRepo
    ) {
        self.enclaveURL = enclaveURL
        self.configRepo = configRepo
    }

    /// Inject the function used to retrieve the user's bearer token.
    /// Called from app startup once the Clerk session is ready.
    func setTokenGetter(_ getter: @escaping @Sendable () async -> String?) {
        self.tokenGetter = getter
    }

    /// Drop the cached client so the next call re-verifies. Used on sign-out.
    func reset() {
        client = nil
        verificationTask?.cancel()
        verificationTask = nil
    }

    /// Force attestation now. Most callers will reach the client via
    /// `post()` / `get()` and let them lazily attest on first use.
    func ready() async throws {
        _ = try await getClient()
    }

    /// Returns the underlying verification document so the UI can render a
    /// trust badge consistent with the chat enclave.
    func verificationDocument() async -> VerificationDocument? {
        client?.verificationDocument
    }

    // MARK: - HTTP

    /// Issue an attested POST against the sync enclave with a JSON body.
    /// `skipAuth: true` is reserved for the share-open path the recipient
    /// reaches without authentication (mirrors the webapp `postPublic`).
    func post<Response: Decodable>(
        path: String,
        body: Encodable? = nil,
        skipAuth: Bool = false
    ) async throws -> Response {
        try Self.assertRelativePath(path)
        let client = try await getClient()
        let url = enclaveURL + path

        var headers: [String: String] = [
            "Accept": "application/json"
        ]
        if !skipAuth {
            headers["Authorization"] = "Bearer \(try await requireToken())"
        }

        let bodyData: Data?
        if let body = body {
            headers["Content-Type"] = "application/json"
            bodyData = try JSONEncoder.enclave.encode(AnyEncodable(body))
        } else {
            bodyData = nil
        }

        let response: SecureResponse
        do {
            response = try await client.post(url: url, headers: headers, body: bodyData)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.wrapTransportError(error)
        }
        return try Self.decode(response: response, path: path)
    }

    /// Issue an attested GET against the sync enclave. Used by `/v1/health`.
    func get<Response: Decodable>(path: String) async throws -> Response {
        try Self.assertRelativePath(path)
        let client = try await getClient()
        let url = enclaveURL + path

        var headers: [String: String] = ["Accept": "application/json"]
        headers["Authorization"] = "Bearer \(try await requireToken())"

        let response: SecureResponse
        do {
            response = try await client.get(url: url, headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.wrapTransportError(error)
        }
        return try Self.decode(response: response, path: path)
    }

    /// Stamp the NETWORK wire code only on transport failures that a
    /// retry can plausibly heal. Everything else (TLS/cert failures,
    /// attestation errors, ...) is rethrown untouched so the recovery
    /// classifier applies its terminal handling instead of retrying a
    /// persistent failure forever.
    private static func wrapTransportError(_ error: Error) -> Error {
        guard EnclaveErrorRecovery.isTransientNetwork(error) else { return error }
        return SyncEnclaveError(
            message: "Sync enclave request failed: \(error.localizedDescription)",
            code: WireCodes.network
        )
    }

    // MARK: - Private

    private func getClient() async throws -> SecureClient {
        if let client {
            return client
        }
        if let existing = verificationTask {
            return try await existing.value
        }
        try Self.assertSecureURL(enclaveURL)
        let task = Task<SecureClient, Error> { [enclaveURL, configRepo] in
            let newClient = SecureClient(
                githubRepo: configRepo,
                enclaveURL: enclaveURL
            )
            _ = try await newClient.verify()
            return newClient
        }
        verificationTask = task

        do {
            let verified = try await task.value
            self.client = verified
            self.verificationTask = nil
            return verified
        } catch {
            self.verificationTask = nil
            throw error
        }
    }

    private func requireToken() async throws -> String {
        guard let token = await tokenGetter?(), !token.isEmpty else {
            throw SyncEnclaveError.authenticationRequired
        }
        return token
    }

    private static func decode<T: Decodable>(response: SecureResponse, path: String) throws -> T {
        if !(200..<300).contains(response.statusCode) {
            throw parseError(response: response)
        }
        // 204 / empty body — allow Void-like responses via OKResponse decode.
        if response.statusCode == 204 || response.body.isEmpty {
            // Synthesize an empty object so decoders that tolerate {} succeed.
            if let empty = "{}".data(using: .utf8),
               let value = try? JSONDecoder.enclave.decode(T.self, from: empty) {
                return value
            }
            throw SyncEnclaveError(
                message: "Sync enclave returned empty body for \(path)",
                status: response.statusCode
            )
        }
        do {
            return try JSONDecoder.enclave.decode(T.self, from: response.body)
        } catch {
            throw SyncEnclaveError(
                message: "Failed to decode sync enclave response: \(error.localizedDescription)",
                status: response.statusCode
            )
        }
    }

    private static func parseError(response: SecureResponse) -> SyncEnclaveError {
        var message = "Sync enclave request failed: HTTP \(response.statusCode)"
        var code: String? = "HTTP_\(response.statusCode)"
        var details: [String: AnyCodable]? = nil
        if !response.body.isEmpty,
           let parsed = try? JSONDecoder.enclave.decode([String: AnyCodable].self, from: response.body) {
            if let errString = parsed["error"]?.value as? String, !errString.isEmpty {
                message = errString
            }
            if let codeString = parsed["code"]?.value as? String, !codeString.isEmpty {
                code = codeString
            }
            details = parsed
        }
        return SyncEnclaveError(
            message: message,
            status: response.statusCode,
            code: code,
            details: details
        )
    }

    /// Requiring a single leading slash already rules out absolute
    /// URLs: a scheme (`https:`, `foo+bar:`) can never start with `/`,
    /// and `//host` protocol-relative forms are rejected explicitly.
    private static func assertRelativePath(_ path: String) throws {
        if !path.hasPrefix("/") || path.hasPrefix("//") {
            throw SyncEnclaveError.invalidPath
        }
    }

    private static func assertSecureURL(_ urlString: String) throws {
        guard let parsed = URL(string: urlString),
              parsed.scheme?.lowercased() == "https",
              let host = parsed.host,
              !host.isEmpty else {
            throw SyncEnclaveError.invalidEnclaveURL
        }
    }
}

// MARK: - Convenience extensions

extension JSONEncoder {
    /// Encoder configured for the sync enclave wire. Snake-case keys are
    /// driven explicitly by each DTO's `CodingKeys`, so the encoder stays
    /// stock; this static factory exists to centralize future tuning.
    static var enclave: JSONEncoder {
        let encoder = JSONEncoder()
        return encoder
    }
}

extension JSONDecoder {
    /// Decoder configured for the sync enclave wire. Mirrors `JSONEncoder.enclave`.
    static var enclave: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

// MARK: - AnyEncodable / AnyCodable

/// Type-erased Encodable wrapper used when we hand off heterogeneous
/// payloads to the JSON encoder (e.g. push body whose body type is
/// known statically but whose call sites mix different shapes).
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) {
        self._encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

/// Lightweight `Codable` value that round-trips arbitrary JSON. Used
/// for metadata blocks whose shape is scope-specific and for decoding
/// the loose `{error, code, ...details}` error envelope.
struct AnyCodable: Codable {
    let value: Any

    init<T>(_ value: T?) {
        self.value = value ?? ()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
