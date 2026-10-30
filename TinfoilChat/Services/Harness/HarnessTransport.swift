import EHBP
import Foundation
import Tinfoil

/// A request to the harness, as the transport sends it: its route, the
/// headers beyond who is asking, and its body, sealed to the enclave.
struct HarnessRequest: Sendable {
    let route: HarnessRoute
    let headers: [String: String]
    let body: Data
}

/// The harness's answer, with its body as it arrives. Header names are
/// lowercased.
struct HarnessResponse: Sendable {
    let status: Int
    let headers: [String: String]
    /// Whether the enclave sealed the answer. Every answer the harness
    /// gives is; one that is not came from whatever stands in front of the
    /// enclave.
    let sealed: Bool
    let body: AsyncThrowingStream<Data, Error>

    var isSuccess: Bool { (200..<300).contains(status) }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The whole body, read to its end.
    func collect() async throws -> Data {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return data
    }

    static func collected(status: Int, headers: [String: String], sealed: Bool, body: Data) -> HarnessResponse {
        HarnessResponse(status: status, headers: headers, sealed: sealed, body: AsyncThrowingStream { continuation in
            continuation.yield(body)
            continuation.finish()
        })
    }
}

/// Carries requests to the harness through an attested, sealed channel.
protocol HarnessTransport: Sendable {
    func send(_ request: HarnessRequest) async throws -> HarnessResponse
    /// The latest verification of the enclave, or nil before the first.
    func verification() async -> Verification?
}

/// The transport to the harness enclave: each request's body is sealed to
/// the X25519 key the enclave's attestation endorses, which the client
/// verifies again as its freshness ends or as the enclave refuses a key it
/// rotated.
actor SealedTransport: HarnessTransport {
    private let origin: URL
    private let enclave: String
    private let repo: String
    /// The enclave's client, made and verified by the first request and
    /// shared by every request after it.
    private var connecting: Task<EnclaveHTTPClient, Error>?

    init(url: String = Constants.Harness.url, repo: String = Constants.Harness.configRepo) throws {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host,
              parsed.user == nil, parsed.password == nil, parsed.path.isEmpty || parsed.path == "/",
              parsed.query == nil, parsed.fragment == nil,
              let origin = URL(string: "https://\(host)" + (parsed.port.map { ":\($0)" } ?? "")) else {
            throw HarnessError(
                code: HarnessErrorCode.configuration,
                message: "Configure an HTTPS origin for the chat service.",
                action: .stop
            )
        }
        self.origin = origin
        enclave = parsed.port.map { "\(host):\($0)" } ?? host
        self.repo = repo
    }

    func verification() async -> Verification? {
        guard let connecting, let client = try? await connecting.value else { return nil }
        return await client.current
    }

    func send(_ request: HarnessRequest) async throws -> HarnessResponse {
        let client = try await client()
        var sent = URLRequest(url: origin.appending(path: request.route.rawValue))
        sent.httpMethod = "POST"
        sent.allHTTPHeaderFields = request.headers
        sent.httpBody = request.body
        sent.timeoutInterval = Constants.Harness.streamIdleTimeoutSeconds
        let answer = try await client.recoverableBytes(for: sent)
        let response = answer.response
        let sealed = response.value(forHTTPHeaderField: EHBPProtocol.responseNonceHeader) != nil
        return HarnessResponse(status: response.statusCode, headers: Self.headers(of: response), sealed: sealed, body: answer.body)
    }

    /// The enclave's client, verified once it is made. One that has not been
    /// made within the attestation timeout, or failed, fails the requests
    /// waiting on it; the next request makes it again.
    private func client() async throws -> EnclaveHTTPClient {
        let task = connecting ?? connect()
        connecting = task
        do {
            return try await task.value
        } catch {
            if connecting == task { connecting = nil }
            throw error
        }
    }

    private func connect() -> Task<EnclaveHTTPClient, Error> {
        let enclave = enclave
        let repo = repo
        return Task {
            try await withThrowingTaskGroup(of: EnclaveHTTPClient.self) { group in
                group.addTask { try await EnclaveHTTPClient(enclave: enclave, repo: repo, transportMode: .ehbp) }
                group.addTask {
                    try await Task.sleep(for: .seconds(Constants.Harness.attestationTimeoutSeconds))
                    throw HarnessError(
                        code: HarnessErrorCode.connection,
                        message: "The chat service could not be verified in time. Check your connection and try again.",
                        action: .retry
                    )
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return headers
    }
}
