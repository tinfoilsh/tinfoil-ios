import ClerkKit
import Foundation

@MainActor
enum SafeguardsAPI {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Constants.Safeguards.requestTimeoutSeconds
        return URLSession(configuration: configuration)
    }()

    static func fetchFlags(userId: String) async throws -> SafeguardFlagsReport {
        guard Clerk.shared.user?.id == userId,
              let clerkSession = Clerk.shared.session else {
            throw SafeguardsError.authenticationRequired
        }
        guard let token = try await clerkSession.getToken(), !token.isEmpty else {
            throw SafeguardsError.authenticationRequired
        }
        try Task.checkCancellation()
        guard Clerk.shared.user?.id == userId,
              Clerk.shared.session?.id == clerkSession.id else {
            throw SafeguardsError.authenticationRequired
        }

        var request = URLRequest(url: Constants.Safeguards.flagsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard Clerk.shared.user?.id == userId,
              Clerk.shared.session?.id == clerkSession.id else {
            throw SafeguardsError.authenticationRequired
        }
        guard let http = response as? HTTPURLResponse else {
            throw SafeguardsError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw SafeguardsError.httpStatus(http.statusCode)
        }
        return try SafeguardFlagsReport.decode(data)
    }
}
