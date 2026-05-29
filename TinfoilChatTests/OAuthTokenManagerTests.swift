import Testing
@testable import TinfoilChat

@Suite("OAuth Token Manager Tests")
struct OAuthTokenManagerTests {

    @Test("Clears refresh state on invalid_grant")
    func clearsRefreshTokenOnInvalidGrant() {
        let error = OAuthTokenManagerError.requestFailed(statusCode: 400, code: "invalid_grant")
        #expect(error.shouldClearRefreshToken == true)
    }

    @Test("Clears refresh state on invalid_client")
    func clearsRefreshTokenOnInvalidClient() {
        let error = OAuthTokenManagerError.requestFailed(statusCode: 401, code: "invalid_client")
        #expect(error.shouldClearRefreshToken == true)
    }

    @Test("Does not clear refresh state on transient server errors")
    func keepsRefreshTokenOnServerError() {
        let error = OAuthTokenManagerError.requestFailed(statusCode: 500, code: "server_error")
        #expect(error.shouldClearRefreshToken == false)
    }
}
