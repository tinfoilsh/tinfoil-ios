import Foundation
import Testing
@testable import Tinfoil
@testable import TinfoilChat

@Suite("Verification badge")
struct VerificationBadgeTests {
    private typealias Badge = ChatViewModel.VerificationInfo

    @Test func aVerificationThatFailsAfterOneThatSucceededClearsTheBadgeAndSaysWhatFailed() async throws {
        let transport = ScriptedTransport([])
        let client = HarnessClient(credentials: ScriptedCredentials(), transport: transport)
        var results = client.verifications.makeAsyncIterator()
        var badge = Badge(isVerifying: true)

        transport.report(.success(.succeeded))
        badge.follow(try #require(await results.next()), sessionOpen: true)
        #expect(badge.isVerified && badge.error == nil)

        transport.report(.failure(.attestation("quote: invalid signature", layer: .quote)))
        badge.follow(try #require(await results.next()), sessionOpen: true)
        #expect(!badge.isVerified && !badge.isVerifying)
        #expect(badge.error == "The enclave's hardware evidence could not be authenticated.")
    }

    @Test func aVerificationBeforeTheSessionOpensLeavesTheBadgeVerifying() {
        var badge = Badge(isVerifying: true)
        badge.follow(.success(.succeeded), sessionOpen: false)
        #expect(badge.isVerifying && !badge.isVerified)
    }

    @Test func aFailureNamesWhatFailed() {
        #expect(Badge.failure(.attestation("policy: measurement mismatch", layer: .policy)) == "The enclave does not meet the required security checks.")
        #expect(Badge.failure(.attestation("unreadable verification payload")) == "The enclave could not be verified.")
        #expect(Badge.failure(.network("offline", urlError: URLError(.notConnectedToInternet))).hasPrefix("The enclave could not be reached"))
    }
}
