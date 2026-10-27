import ClerkKit
import Foundation

/// The signed-in account's identity, as its Clerk session token.
enum ClerkIdentity {
    /// The session's token, or nil when signed out. Refreshing asks Clerk
    /// for a new token rather than its cached one; a failure to reach Clerk
    /// is thrown, so an outage is retried rather than taken for a revoked
    /// session.
    static func token(refresh: Bool) async throws -> String? {
        guard await !Clerk.shared.publishableKey.isEmpty else { return nil }
        if await !Clerk.shared.isLoaded {
            try await Clerk.shared.refreshClient()
        }
        // No session is the only condition that means "signed out".
        guard let session = await Clerk.shared.session else { return nil }
        if refresh {
            return try await session.getToken(.init(skipCache: true))
        }
        if let token = try? await session.getToken() { return token }
        return session.lastActiveToken?.jwt
    }
}
