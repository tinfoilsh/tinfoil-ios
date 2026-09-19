//
//  ShareAPIService.swift
//  TinfoilChat
//
//  API service for uploading encrypted shared chat data.
//  Matches the React web app's share-api.ts implementation.
//

import Foundation
import ClerkKit

/// Service for share API operations
enum ShareAPIService {

    static func getShareStatus(chatId: String) async throws -> Bool {
        let token = try await getAuthToken()
        let request = try makeStatusRequest(chatId: chatId, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeShareStatus(data: data, response: response)
    }

    static func deleteSharedChat(chatId: String) async throws {
        let token = try await getAuthToken()
        let request = try makeDeleteRequest(chatId: chatId, token: token)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateDeleteResponse(response)
    }

    static func makeStatusRequest(chatId: String, token: String) throws -> URLRequest {
        guard let url = URL(string: "\(Constants.API.baseURL)\(Constants.Share.shareAPIPath)/\(chatId)/status") else {
            throw ShareAPIError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func makeDeleteRequest(chatId: String, token: String) throws -> URLRequest {
        guard let url = URL(string: "\(Constants.API.baseURL)\(Constants.Share.shareAPIPath)/\(chatId)") else {
            throw ShareAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func decodeShareStatus(data: Data, response: URLResponse) throws -> Bool {
        guard let response = response as? HTTPURLResponse,
              Constants.API.successStatusCodes.contains(response.statusCode) else {
            throw ShareAPIError.statusFailed
        }
        struct ShareStatus: Decodable {
            let shared: Bool
        }
        return try JSONDecoder().decode(ShareStatus.self, from: data).shared
    }

    static func validateDeleteResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              Constants.API.successStatusCodes.contains(response.statusCode) else {
            throw ShareAPIError.revokeFailed
        }
    }

    /// Upload enclave-sealed shared chat data to the server as v1 binary.
    /// Endpoint: PUT {baseURL}/api/shares/{chatId}
    /// Requires authentication via Clerk Bearer token.
    static func uploadSharedChat(chatId: String, encryptedData: Data) async throws {
        let urlString = "\(Constants.API.baseURL)\(Constants.Share.shareAPIPath)/\(chatId)"
        guard let url = URL(string: urlString) else {
            throw ShareAPIError.invalidURL
        }

        let token = try await getAuthToken()

        let request = makeUploadRequest(url: url, encryptedData: encryptedData, token: token)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              Constants.API.successStatusCodes.contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ShareAPIError.uploadFailed(statusCode: statusCode)
        }
    }

    static func makeUploadRequest(url: URL, encryptedData: Data, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(ShareV2Contract.uploadFormatVersion, forHTTPHeaderField: "X-Format-Version")
        request.httpBody = encryptedData
        return request
    }

    // MARK: - Auth Helper

    private static func getAuthToken() async throws -> String {
        let isLoaded = await Clerk.shared.isLoaded
        if !isLoaded {
            try await Clerk.shared.refreshClient()
        }

        if let session = await Clerk.shared.session {
            if let token = try? await session.getToken() {
                return token
            } else if let tokenResource = session.lastActiveToken {
                return tokenResource.jwt
            }
        }

        throw ShareAPIError.authenticationRequired
    }
}

// MARK: - Errors

enum ShareAPIError: LocalizedError {
    case invalidURL
    case authenticationRequired
    case uploadFailed(statusCode: Int)
    case statusFailed
    case revokeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid share URL"
        case .authenticationRequired:
            return "Authentication required to share"
        case .uploadFailed(let statusCode):
            return "Failed to upload shared chat (status \(statusCode))"
        case .statusFailed:
            return "Unable to check whether a share link is active. Please try again."
        case .revokeFailed:
            return "Could not disable sharing. The link may still be active. Please try again."
        }
    }
}
