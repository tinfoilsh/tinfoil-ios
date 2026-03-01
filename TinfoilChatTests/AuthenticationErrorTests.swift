import Testing
import Foundation
@testable import TinfoilChat
import OpenAI
import TinfoilAI

@Suite("Authentication Error Detection Tests")
@MainActor
struct AuthenticationErrorTests {

    /// Helper to create an APIErrorResponse from JSON since the memberwise init isn't public
    private static func makeAPIErrorResponse(message: String, type: String, code: String?) -> APIErrorResponse {
        var codeJSON = "null"
        if let code = code {
            codeJSON = "\"\(code)\""
        }
        let json = """
        {"error":{"message":"\(message)","type":"\(type)","param":null,"code":\(codeJSON)}}
        """
        return try! JSONDecoder().decode(APIErrorResponse.self, from: json.data(using: .utf8)!)
    }

    // MARK: - Unit tests: OpenAIError.statusError

    @Test("Detects OpenAIError.statusError with 401 as auth error")
    func detectsStatusError401() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        let error = OpenAIError.statusError(response: response, statusCode: 401)
        #expect(ChatViewModel.isAuthenticationError(error) == true)
    }

    @Test("Does NOT detect OpenAIError.statusError with 403 as auth error")
    func doesNotDetectStatusError403() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        let error = OpenAIError.statusError(response: response, statusCode: 403)
        #expect(ChatViewModel.isAuthenticationError(error) == false)
    }

    @Test("Does NOT detect OpenAIError.statusError with 500 as auth error")
    func doesNotDetectStatusError500() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        let error = OpenAIError.statusError(response: response, statusCode: 500)
        #expect(ChatViewModel.isAuthenticationError(error) == false)
    }

    // MARK: - Unit tests: APIErrorResponse

    @Test("Detects APIErrorResponse with invalid_api_key code as auth error")
    func detectsAPIErrorResponseInvalidKey() {
        let error = Self.makeAPIErrorResponse(
            message: "Session token has expired.",
            type: "invalid_request_error",
            code: "invalid_api_key"
        )
        #expect(ChatViewModel.isAuthenticationError(error) == true)
    }

    @Test("Does NOT detect APIErrorResponse with different code as auth error")
    func doesNotDetectAPIErrorResponseOtherCode() {
        let error = Self.makeAPIErrorResponse(
            message: "Rate limit exceeded",
            type: "rate_limit_error",
            code: "rate_limit_exceeded"
        )
        #expect(ChatViewModel.isAuthenticationError(error) == false)
    }

    @Test("Does NOT detect APIErrorResponse with nil code as auth error")
    func doesNotDetectAPIErrorResponseNilCode() {
        let error = Self.makeAPIErrorResponse(
            message: "Something went wrong",
            type: "server_error",
            code: nil
        )
        #expect(ChatViewModel.isAuthenticationError(error) == false)
    }

    // MARK: - Unit tests: other error types

    @Test("Does NOT detect generic NSError as auth error")
    func doesNotDetectGenericNSError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(ChatViewModel.isAuthenticationError(error) == false)
    }

    @Test("Does NOT detect OpenAIError.emptyData as auth error")
    func doesNotDetectEmptyDataError() {
        let error = OpenAIError.emptyData
        #expect(ChatViewModel.isAuthenticationError(error) == false)
    }

    // MARK: - Live API: streaming path

    @Test("Streaming with bad API key throws error detected by isAuthenticationError")
    func streamingBadKeyDetected() async throws {
        let client = try await TinfoilAI.create(apiKey: "sk-bad-key-that-does-not-exist")

        let chatQuery = ChatQuery(
            messages: [.user(.init(content: .string("Hello")))],
            model: "gpt-oss-120b"
        )

        let stream = client.chatsStream(query: chatQuery)

        var caughtError: Error? = nil
        do {
            for try await _ in stream {}
        } catch {
            caughtError = error
        }

        #expect(caughtError != nil, "Expected an error from streaming with bad API key")
        if let error = caughtError {
            #expect(
                ChatViewModel.isAuthenticationError(error),
                "isAuthenticationError should return true, but got error type: \(type(of: error)), value: \(error)"
            )
        }
    }

    // MARK: - Live API: non-streaming path

    @Test("Non-streaming with bad API key throws error detected by isAuthenticationError")
    func nonStreamingBadKeyDetected() async throws {
        let client = try await TinfoilAI.create(apiKey: "sk-bad-key-that-does-not-exist")

        let chatQuery = ChatQuery(
            messages: [.user(.init(content: .string("Hello")))],
            model: "gpt-oss-120b"
        )

        var caughtError: Error? = nil
        do {
            let _: ChatResult = try await client.chats(query: chatQuery)
        } catch {
            caughtError = error
        }

        #expect(caughtError != nil, "Expected an error from non-streaming with bad API key")
        if let error = caughtError {
            #expect(
                ChatViewModel.isAuthenticationError(error),
                "isAuthenticationError should return true, but got error type: \(type(of: error)), value: \(error)"
            )
        }
    }
}
