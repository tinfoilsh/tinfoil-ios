import Foundation
import Testing
@testable import TinfoilChat

@Suite("Redirect refusal")
struct RedirectRefusalTests {
    @Test func answersWithTheRedirectInsteadOfFollowingIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let session = URLSession(configuration: configuration, delegate: RedirectRefusal.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(from: RedirectingProtocol.origin)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == RedirectingProtocol.redirectStatus)
        #expect(http.url == RedirectingProtocol.origin)
    }
}

/// Redirects every request for `origin` elsewhere, and answers any other
/// request with a success.
private final class RedirectingProtocol: URLProtocol {
    static let origin = URL(string: "https://origin.invalid/resource")!
    static let elsewhere = URL(string: "https://elsewhere.invalid/resource")!
    static let redirectStatus = 302
    static let successStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        if url == Self.origin {
            let redirect = HTTPURLResponse(url: url, statusCode: Self.redirectStatus, httpVersion: nil, headerFields: ["Location": Self.elsewhere.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.elsewhere), redirectResponse: redirect)
            client.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        } else {
            let success = HTTPURLResponse(url: url, statusCode: Self.successStatus, httpVersion: nil, headerFields: nil)!
            client.urlProtocol(self, didReceive: success, cacheStoragePolicy: .notAllowed)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
