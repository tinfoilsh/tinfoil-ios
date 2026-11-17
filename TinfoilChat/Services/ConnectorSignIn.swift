import AuthenticationServices
import UIKit
import os

/// What the user comes back from a connector's sign-in page with: a code and
/// the state the sign-in started with, and the issuer when the authorization
/// server names one, or the error it refused the sign-in with.
struct ConnectorSignInAnswer: Equatable, Sendable {
    var code: String?
    var state: String?
    var issuer: String?
    var error: String?

    init(code: String? = nil, state: String? = nil, issuer: String? = nil, error: String? = nil) {
        self.code = code
        self.state = state
        self.issuer = issuer
        self.error = error
    }

    /// What the address a sign-in page sent the user back to holds.
    init(callback: URL) {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(code: value("code"), state: value("state"), issuer: value("iss"), error: value("error"))
    }
}

/// Where a sign-in page sends the user back to, as the page's address names
/// it: the callback the chat service registered with the authorization
/// server.
struct ConnectorSignInCallback: Equatable, Sendable {
    var host: String
    var path: String

    private static let redirectParameter = "redirect_uri"

    init?(page: URL) {
        guard page.scheme == "https",
              let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == Self.redirectParameter })?.value,
              let redirect = URL(string: address), redirect.scheme == "https",
              let host = redirect.host, !host.isEmpty else { return nil }
        self.host = host
        self.path = redirect.path
    }
}

/// Sends the user to a connector's sign-in page and waits for them.
@MainActor
protocol ConnectorSignInPresenting: AnyObject {
    /// What the user came back from the page with, or nil when they closed
    /// it.
    func signIn(at page: URL) async throws -> ConnectorSignInAnswer?
}

/// Signs the user in to a connector in a sheet over the app. The
/// authorization server's page ends by sending the user to the callback the
/// chat service registered, an address of the web app that this app is
/// associated with, so the sheet hands the address to the app rather than
/// load it. The code it carries only passes through the app: the chat
/// service trades it for tokens it keeps.
@MainActor
final class ConnectorSignInSheet: NSObject, ConnectorSignInPresenting, ASWebAuthenticationPresentationContextProviding {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Connectors")

    /// The sheet could not be shown.
    private struct NotStarted: Error {}

    private var session: ASWebAuthenticationSession?
    private lazy var fallbackAnchor = UIWindow(frame: .zero)

    func signIn(at page: URL) async throws -> ConnectorSignInAnswer? {
        guard let callback = ConnectorSignInCallback(page: page) else {
            throw HarnessError(code: HarnessErrorCode.connectorSignInFailed, message: "The sign-in page has an invalid address.", action: .stop)
        }
        // A sign-in started while another shows replaces it.
        session?.cancel()
        do {
            let address = try await open(page, callback: callback)
            return ConnectorSignInAnswer(callback: address)
        } catch {
            if isUserCancellation(error) { return nil }
            Self.logger.error("Failed to open a connector's sign-in page: \(error, privacy: .public)")
            throw HarnessError(code: HarnessErrorCode.connectorSignInFailed, message: "The sign-in page could not be opened.", action: .stop)
        }
    }

    /// The address the page sent the user back to.
    private func open(_ page: URL, callback: ConnectorSignInCallback) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            // The sheet answers once, whether it ends or never starts.
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Result<URL, Error>) -> Void = { result in
                let first = answered.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            let session = ASWebAuthenticationSession(url: page, callback: .https(host: callback.host, path: callback.path)) { address, error in
                if let address {
                    answer(.success(address))
                } else {
                    answer(.failure(error ?? CancellationError()))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                answer(.failure(NotStarted()))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        TinfoilPasskeyPresentationAnchorProvider.activeWindow() ?? fallbackAnchor
    }
}
