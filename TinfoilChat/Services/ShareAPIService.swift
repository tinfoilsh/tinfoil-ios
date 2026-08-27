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
              (200...299).contains(httpResponse.statusCode) else {
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

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid share URL"
        case .authenticationRequired:
            return "Authentication required to share"
        case .uploadFailed(let statusCode):
            return "Failed to upload shared chat (status \(statusCode))"
        }
    }
}
