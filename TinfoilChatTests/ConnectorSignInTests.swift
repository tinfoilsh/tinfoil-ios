import Foundation
import Testing
@testable import TinfoilChat

@Suite("Connector sign-in")
struct ConnectorSignInTests {
    private static func address(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    @Test func theAddressTheUserComesBackToAnswersWithItsCodeStateAndIssuer() throws {
        let callback = try Self.address("https://chat.tinfoil.sh/connectors/callback?code=code-1&state=state-1&iss=https%3A%2F%2Fauth.example.test")
        #expect(ConnectorSignInAnswer(callback: callback) == ConnectorSignInAnswer(code: "code-1", state: "state-1", issuer: "https://auth.example.test"))

        // A value left empty, or named without one, is absent.
        let partial = try Self.address("https://chat.tinfoil.sh/connectors/callback?code=&state=state-1&iss")
        #expect(ConnectorSignInAnswer(callback: partial) == ConnectorSignInAnswer(state: "state-1"))

        let bare = try Self.address("https://chat.tinfoil.sh/connectors/callback")
        #expect(ConnectorSignInAnswer(callback: bare) == ConnectorSignInAnswer())
    }

    @Test func theAddressOfASignInTheAuthorizationServerRefusedAnswersWithItsError() throws {
        let callback = try Self.address("https://chat.tinfoil.sh/connectors/callback?error=access_denied&error_description=declined&state=state-1")
        #expect(ConnectorSignInAnswer(callback: callback) == ConnectorSignInAnswer(state: "state-1", error: "access_denied"))
    }

    @Test func aSignInPageNamesTheAddressItSendsTheUserBackTo() throws {
        let page = try Self.address("https://auth.example.test/authorize?client_id=tinfoil&redirect_uri=https%3A%2F%2Fchat.tinfoil.sh%2Fconnectors%2Fcallback&state=state-1")
        let callback = try #require(ConnectorSignInCallback(page: page))
        #expect(callback.host == "chat.tinfoil.sh")
        #expect(callback.path == "/connectors/callback")
    }

    @Test(arguments: [
        // The page is not HTTPS.
        "http://auth.example.test/authorize?redirect_uri=https%3A%2F%2Fchat.tinfoil.sh%2Fconnectors%2Fcallback",
        // The page names no address to come back to.
        "https://auth.example.test/authorize",
        "https://auth.example.test/authorize?client_id=tinfoil&state=state-1",
        // The address to come back to is not HTTPS.
        "https://auth.example.test/authorize?redirect_uri=http%3A%2F%2Fchat.tinfoil.sh%2Fconnectors%2Fcallback",
        "https://auth.example.test/authorize?redirect_uri=tinfoil%3A%2F%2Fconnectors%2Fcallback",
    ])
    func aPageThatNamesNoHTTPSAddressToComeBackToHasNoCallback(_ page: String) throws {
        let address = try Self.address(page)
        #expect(ConnectorSignInCallback(page: address) == nil)
    }
}
