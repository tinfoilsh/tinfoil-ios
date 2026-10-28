import EHBP
import Foundation
import TinfoilAI

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
/// the X25519 key the enclave's attestation endorses, which is verified
/// again as its freshness ends or as the enclave refuses a key it rotated.
final class SealedTransport: HarnessTransport {
    private let origin: String
    private let handle: EnclaveHandle
    private let session: URLSession

    init(url: String = Constants.Harness.url, repo: String = Constants.Harness.configRepo) throws {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host,
              parsed.user == nil, parsed.password == nil, parsed.path.isEmpty || parsed.path == "/",
              parsed.query == nil, parsed.fragment == nil else {
            throw HarnessError(
                code: HarnessErrorCode.configuration,
                message: "Configure an HTTPS origin for the chat service.",
                action: .stop
            )
        }
        origin = "https://\(host)" + (parsed.port.map { ":\($0)" } ?? "")
        handle = try EnclaveHandle(enclave: parsed.port.map { "\(host):\($0)" } ?? host, repo: repo)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.Harness.streamIdleTimeoutSeconds
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RedirectRefusal.shared, delegateQueue: nil)
    }

    func verification() async -> Verification? {
        await handle.verification
    }

    func send(_ request: HarnessRequest) async throws -> HarnessResponse {
        for attempt in 0..<2 {
            let key = try await publicKey()
            try Task.checkCancellation()
            let client = try EHBPClient(baseURL: origin, publicKey: key, session: session)
            do {
                let (stream, response) = try await client.requestStream(
                    method: "POST",
                    path: request.route.rawValue,
                    headers: request.headers,
                    body: request.body
                )
                let sealed = response.value(forHTTPHeaderField: EHBPProtocol.responseNonceHeader) != nil
                return HarnessResponse(status: response.statusCode, headers: Self.headers(of: response), sealed: sealed, body: stream)
            } catch let error as EHBPError where error.code == .keyConfigMismatch {
                // The enclave rotated its key since it was verified; the
                // request is sealed again, once, to the key verified now.
                guard attempt == 0 else { break }
                _ = try await verified(again: true)
            }
        }
        throw HarnessError(
            code: HarnessErrorCode.connection,
            message: "The chat service refused the key it was verified with.",
            action: .retry
        )
    }

    /// The key requests are sealed to, from the enclave's verification.
    private func publicKey() async throws -> Data {
        let verification = try await verified(again: false)
        guard let hex = verification.hpkePublicKey, let key = Data(lowercaseHex: hex),
              key.count == Constants.Harness.hpkePublicKeyBytes else {
            throw HarnessError(
                code: HarnessErrorCode.configuration,
                message: "The chat service endorses no key to seal requests to.",
                action: .stop
            )
        }
        return key
    }

    /// The enclave's verification, fresh or made again, within the
    /// attestation timeout. One that has not finished by then fails the
    /// request; the next one asks again.
    private func verified(again: Bool) async throws -> Verification {
        try await withThrowingTaskGroup(of: Verification.self) { group in
            group.addTask { try await again ? self.handle.verify() : self.handle.verifyIfNeeded() }
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

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return headers
    }
}
