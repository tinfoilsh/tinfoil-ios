//
//  EnclaveTransport.swift
//  TinfoilChat
//
//  Attested requests to Tinfoil's non-inference enclaves (sync,
//  summarizer, link metadata, document conversion) through the SDK's
//  `EnclaveHandle`, which pins every connection to the enclave's attested
//  TLS key and re-verifies when the attestation expires.
//

import Foundation
import TinfoilAI

/// Requests to one attested enclave. `EnclaveHandle` is the real one; tests
/// substitute a stand-in.
protocol EnclaveTransport: Sendable {
    /// Verifies the enclave unless a verification still authorizes requests
    func prepare() async throws

    /// Sends a request over TLS pinned to the enclave's attested key,
    /// verifying first when needed
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension EnclaveTransport {
    func post(
        url: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await send(method: "POST", url: url, headers: headers, body: body)
    }

    func get(
        url: String,
        headers: [String: String] = [:]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await send(method: "GET", url: url, headers: headers, body: nil)
    }

    private func send(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let target = URL(string: url) else {
            throw TinfoilError.invalidConfiguration("invalid enclave request URL: \(url)")
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        let (data, response) = try await self.data(for: request)
        return (data, response)
    }
}

extension EnclaveHandle: EnclaveTransport {
    /// A handle on the enclave serving `url`, an absolute HTTPS URL such as
    /// `Constants.Summarizer.enclaveURL`, verified against `repo`
    static func enclave(at url: String, repo: String) throws -> EnclaveHandle {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty else {
            throw TinfoilError.invalidConfiguration("enclave URL must be an absolute HTTPS URL, not \(url)")
        }
        let enclave = components.port.map { "\(host):\($0)" } ?? host
        return try EnclaveHandle(enclave: enclave, repo: repo)
    }

    func prepare() async throws {
        _ = try await verifyIfNeeded()
    }
}
