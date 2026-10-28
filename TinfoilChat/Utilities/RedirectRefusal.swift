import Foundation

/// Refuses every HTTP redirect, so a request reaches only the origin it
/// names, with the credentials it carries; the redirect itself is the
/// answer.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusal()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension URLSession {
    /// A session that keeps no cache, cookies or credentials on disk, and
    /// follows no redirect.
    static func ephemeralRefusingRedirects(timeout: TimeInterval? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        if let timeout { configuration.timeoutIntervalForRequest = timeout }
        return URLSession(configuration: configuration, delegate: RedirectRefusal.shared, delegateQueue: nil)
    }
}
