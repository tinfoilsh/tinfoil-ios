import ClerkKit
import Foundation

/// The signed-in account's identity, as its Clerk session token.
enum ClerkIdentity {
    /// The session's token, or nil when signed out. Refreshing asks Clerk
    /// for a new token rather than its cached one. A failure to reach Clerk
    /// falls back to the token last issued, and is thrown when there is
    /// none, so an outage is retried rather than taken for a revoked
    /// session.
    /// The signed-in user's id, or nil when signed out.
    static func userId() async -> String? {
        await Clerk.shared.user?.id
    }

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
        do {
            return try await session.getToken() ?? session.lastActiveToken?.jwt
        } catch {
            guard let last = session.lastActiveToken?.jwt else { throw error }
            return last
        }
    }
}
