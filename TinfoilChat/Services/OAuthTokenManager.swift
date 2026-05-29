//
//  OAuthTokenManager.swift
//  TinfoilChat
//
//  Created on 05/29/26.
//  Copyright © 2026 Tinfoil. All rights reserved.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct OAuthAccessToken {
    let value: String
    let expiresAt: Date
}

enum OAuthTokenManagerError: LocalizedError {
    case notConfigured
    case randomBytesUnavailable
    case invalidAuthorizationURL
    case invalidCallbackState
    case missingAuthorizationCode
    case cancelled
    case requestFailed(statusCode: Int, code: String?)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OAuth client ID is not configured."
        case .randomBytesUnavailable:
            return "Could not generate secure random bytes."
        case .invalidAuthorizationURL:
            return "Could not build the OAuth authorization URL."
        case .invalidCallbackState:
            return "OAuth callback state did not match."
        case .missingAuthorizationCode:
            return "OAuth callback did not include an authorization code."
        case .cancelled:
            return "OAuth authorization was cancelled."
        case .requestFailed(let statusCode, let code):
            return code ?? "OAuth token request failed with status \(statusCode)."
        case .invalidTokenResponse:
            return "OAuth token response was invalid."
        }
    }

    var shouldClearRefreshToken: Bool {
        if case .requestFailed(_, let code) = self {
            return code == "invalid_grant" || code == "invalid_client"
        }
        return false
    }
}

final class OAuthTokenManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthTokenManager()

    private let keychain = KeychainHelper.shared
    // Guards `accessToken` and `inFlightTask`, which may be touched concurrently
    // by callers on different threads. `webAuthenticationSession` is only ever
    // mutated on the main actor and so does not need the lock.
    private let stateLock = NSLock()
    private var accessToken: OAuthAccessToken?
    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var inFlightTask: Task<OAuthAccessToken?, Error>?
    private let decoder = JSONDecoder()

    private override init() {}

    var isConfigured: Bool {
        !Constants.OAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasRefreshToken: Bool {
        loadRefreshToken() != nil
    }

    func getAccessToken() async throws -> OAuthAccessToken? {
        guard isConfigured else {
            return nil
        }

        if let cached = validCachedToken() {
            return cached
        }

        // Coalesce concurrent callers so a rotating refresh token is only spent
        // once and only a single authorization session is ever presented.
        return try await currentFetchTask().value
    }

    private func resolveAccessToken() async throws -> OAuthAccessToken? {
        if let cached = validCachedToken() {
            return cached
        }

        if hasRefreshToken {
            do {
                if let refreshed = try await refreshAccessToken() {
                    return refreshed
                }
            } catch let error as OAuthTokenManagerError where error.shouldClearRefreshToken {
                clearTokens()
            }
        }

        return try await authorize()
    }

    private func currentFetchTask() -> Task<OAuthAccessToken?, Error> {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let inFlightTask {
            return inFlightTask
        }

        let task = Task { [weak self] () throws -> OAuthAccessToken? in
            guard let self = self else { return nil }
            defer { self.clearFetchTask() }
            return try await self.resolveAccessToken()
        }
        inFlightTask = task
        return task
    }

    private func clearFetchTask() {
        stateLock.lock()
        inFlightTask = nil
        stateLock.unlock()
    }

    private func validCachedToken() -> OAuthAccessToken? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let accessToken, !isExpiring(accessToken.expiresAt) else {
            return nil
        }
        return accessToken
    }

    private func setAccessToken(_ token: OAuthAccessToken) {
        stateLock.lock()
        accessToken = token
        stateLock.unlock()
    }

    private func currentAccessTokenValue() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accessToken?.value
    }

    func clearAccessToken() {
        stateLock.lock()
        accessToken = nil
        stateLock.unlock()
    }

    func clearTokens() {
        stateLock.lock()
        accessToken = nil
        stateLock.unlock()
        keychain.delete(for: Constants.StorageKeys.Secret.oauthRefreshToken)
    }

    func revokeAndClearTokens() async {
        let tokenToRevoke = loadRefreshToken() ?? currentAccessTokenValue()

        defer {
            clearTokens()
        }

        guard isConfigured, let tokenToRevoke else {
            return
        }

        var request = URLRequest(url: Constants.OAuth.revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": Constants.OAuth.clientID,
            "token": tokenToRevoke
        ])

        _ = try? await URLSession.shared.data(for: request)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func authorize() async throws -> OAuthAccessToken {
        guard isConfigured else {
            throw OAuthTokenManagerError.notConfigured
        }

        let state = try Self.randomBase64URL(byteCount: Constants.OAuth.stateByteCount)
        let codeVerifier = try Self.randomBase64URL(byteCount: Constants.OAuth.codeVerifierByteCount)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)

        var components = URLComponents(url: Constants.OAuth.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Constants.OAuth.clientID),
            URLQueryItem(name: "redirect_uri", value: Constants.OAuth.redirectURI),
            URLQueryItem(name: "scope", value: Constants.OAuth.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authorizationURL = components?.url else {
            throw OAuthTokenManagerError.invalidAuthorizationURL
        }

        let callbackURL = try await startAuthenticationSession(url: authorizationURL)
        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let callbackState = callbackComponents?.queryItems?.first { $0.name == "state" }?.value

        guard callbackState == state else {
            throw OAuthTokenManagerError.invalidCallbackState
        }

        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthTokenManagerError.missingAuthorizationCode
        }

        return try await exchangeAuthorizationCode(code, codeVerifier: codeVerifier)
    }

    @MainActor
    private func startAuthenticationSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Constants.OAuth.redirectScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.webAuthenticationSession = nil
                }

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }

                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    continuation.resume(throwing: OAuthTokenManagerError.cancelled)
                    return
                }

                continuation.resume(throwing: error ?? OAuthTokenManagerError.cancelled)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession = session

            if !session.start() {
                webAuthenticationSession = nil
                continuation.resume(throwing: OAuthTokenManagerError.cancelled)
            }
        }
    }

    private func exchangeAuthorizationCode(_ code: String, codeVerifier: String) async throws -> OAuthAccessToken {
        try await requestToken([
            "grant_type": "authorization_code",
            "client_id": Constants.OAuth.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": Constants.OAuth.redirectURI
        ])
    }

    private func refreshAccessToken() async throws -> OAuthAccessToken? {
        guard let refreshToken = loadRefreshToken() else {
            return nil
        }

        return try await requestToken([
            "grant_type": "refresh_token",
            "client_id": Constants.OAuth.clientID,
            "refresh_token": refreshToken
        ])
    }

    private func requestToken(_ params: [String: String]) async throws -> OAuthAccessToken {
        var request = URLRequest(url: Constants.OAuth.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(params)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthTokenManagerError.invalidTokenResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? decoder.decode(OAuthErrorResponse.self, from: data)
            throw OAuthTokenManagerError.requestFailed(
                statusCode: httpResponse.statusCode,
                code: errorResponse?.error
            )
        }

        let tokenResponse = try decoder.decode(OAuthTokenResponse.self, from: data)
        guard tokenResponse.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw OAuthTokenManagerError.invalidTokenResponse
        }

        let token = OAuthAccessToken(
            value: tokenResponse.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
        setAccessToken(token)

        if let refreshToken = tokenResponse.refreshToken, !refreshToken.isEmpty {
            keychain.save(refreshToken, for: Constants.StorageKeys.Secret.oauthRefreshToken)
        }

        return token
    }

    private func loadRefreshToken() -> String? {
        keychain.loadString(for: Constants.StorageKeys.Secret.oauthRefreshToken)
    }

    private func isExpiring(_ expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSinceNow <= Constants.OAuth.accessTokenExpiryBufferSeconds
    }

    private func formBody(_ params: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw OAuthTokenManagerError.randomBytesUnavailable
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String?
}
