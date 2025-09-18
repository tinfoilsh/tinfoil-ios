//
//  ProfileSyncService.swift
//  TinfoilChat
//
//  Service for syncing user profiles to cloud
//

import Foundation
import Clerk

/// Service for managing profile synchronization with cloud
@MainActor
class ProfileSyncService: ObservableObject {
    static let shared = ProfileSyncService()
    
    private let apiBaseURL = Constants.API.baseURL
    private var getToken: (() async -> String?)? = nil
    private var cachedProfile: ProfileData? = nil
    private var failedDecryptionData: String? = nil
    
    // Shared ISO8601 formatter with fractional seconds for consistency
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private init() {}
    
    // MARK: - Configuration
    
    /// Set the token getter function for authentication
    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) {
        self.getToken = tokenGetter
    }
    
    /// Default token getter using Clerk
    private func defaultTokenGetter() async -> String? {
        do {
            // Ensure Clerk is loaded
            let isLoaded = Clerk.shared.isLoaded
            if !isLoaded {
                try await Clerk.shared.load()
            }
            
            // Get session token
            if let session = Clerk.shared.session,
               let tokenResource = session.lastActiveToken {
                return tokenResource.jwt
            }
            
            return nil
        } catch {
            return nil
        }
    }
    
    /// Check if user is authenticated
    func isAuthenticated() async -> Bool {
        let token = await (getToken ?? defaultTokenGetter)()
        return token != nil && !token!.isEmpty
    }
    
    // MARK: - API Headers
    
    private func getHeaders() async throws -> [String: String] {
        guard let token = await (getToken ?? defaultTokenGetter)() else {
            throw ProfileSyncError.authenticationRequired
        }
        
        // Check if token looks valid (basic check)
        if token.isEmpty {
            throw ProfileSyncError.authenticationRequired
        }
        
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }
    
    // MARK: - Profile Operations
    
    /// Fetch profile from cloud
    func fetchProfile() async throws -> ProfileData? {
        guard await isAuthenticated() else {
            return nil
        }
        
        
        guard let url = URL(string: "\(apiBaseURL)/api/profile/") else {
            throw ProfileSyncError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProfileSyncError.fetchFailed(underlying: error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProfileSyncError.invalidResponse
        }
        
        if httpResponse.statusCode == 404 {
            return nil
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let error = URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url, "statusCode": httpResponse.statusCode])
            throw ProfileSyncError.fetchFailed(underlying: error)
        }
        
        let profileResponse = try JSONDecoder().decode(ProfileResponse.self, from: data)
        
        
        // Initialize encryption service
        _ = try await EncryptionService.shared.initialize()
        
        // Try to decrypt the profile data
        do {
            // Parse the encrypted data (JSON string format)
            guard let encryptedData = profileResponse.data.data(using: .utf8) else {
                throw ProfileSyncError.invalidDataFormat
            }
            
            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: encryptedData)
            
            
            let decryptionResult = try await EncryptionService.shared.decrypt(encrypted, as: ProfileData.self)
            let decrypted = decryptionResult.value
            
            // Cache the decrypted profile
            self.cachedProfile = decrypted
            self.failedDecryptionData = nil
            
            if decryptionResult.usedFallbackKey {
                queueProfileReencryption(for: decrypted, remoteVersion: profileResponse.version)
            }
            
            
            return decrypted
        } catch {
            // Failed to decrypt - store for later retry
            self.failedDecryptionData = profileResponse.data
            self.cachedProfile = nil
            
            
            return nil
        }
    }
    
    /// Save profile to cloud
    func saveProfile(_ profile: ProfileData) async throws -> (success: Bool, version: Int?) {
        guard await isAuthenticated() else {
            return (false, nil)
        }
        
        
        // Initialize encryption service
        _ = try await EncryptionService.shared.initialize()
        
        // Add metadata
        var profileWithMetadata = profile
        profileWithMetadata.updatedAt = Self.iso8601Formatter.string(from: Date())
        profileWithMetadata.version = (profile.version ?? 0) + 1
        
        // Encrypt the profile data
        let encrypted = try await EncryptionService.shared.encrypt(profileWithMetadata)
        
        
        // Send encrypted data as JSON string
        let encryptedData = try JSONEncoder().encode(encrypted)
        guard let jsonString = String(data: encryptedData, encoding: .utf8) else {
            throw ProfileSyncError.encodingFailed
        }
        
        // Create upload request
        guard let url = URL(string: "\(apiBaseURL)/api/profile/") else {
            throw ProfileSyncError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = try await getHeaders()
        
        let body = ProfileUploadRequest(data: jsonString)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProfileSyncError.saveFailed(underlying: error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let error = URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url, "statusCode": (response as? HTTPURLResponse)?.statusCode ?? 0])
            throw ProfileSyncError.saveFailed(underlying: error)
        }
        
        // Try to parse the response to get the server-assigned version
        var serverVersion = profileWithMetadata.version
        if let responseData = try? JSONDecoder().decode(ProfileUploadResponse.self, from: data) {
            serverVersion = responseData.version
        }
        
        // Update cache with server version
        profileWithMetadata.version = serverVersion
        self.cachedProfile = profileWithMetadata
        
        
        return (true, serverVersion)
    }
    
    private func queueProfileReencryption(for profile: ProfileData, remoteVersion: String?) {
        Task { [weak self] in
            guard let self else { return }
            await self.reencryptProfileWithActiveKey(profile, remoteVersion: remoteVersion)
        }
    }
    
    @MainActor
    private func reencryptProfileWithActiveKey(_ profile: ProfileData, remoteVersion: String?) async {
        var profileForUpload = profile
        if let remoteVersion,
           let remoteVersionInt = Int(remoteVersion) {
            let currentVersion = profileForUpload.version ?? 0
            profileForUpload.version = max(currentVersion, remoteVersionInt)
        }
        do {
            _ = try await saveProfile(profileForUpload)
        } catch {
#if DEBUG
            print("[ProfileSync] Failed to re-encrypt profile with active key: \(error)")
#endif
        }
    }
    
    /// Retry decryption with new key
    func retryDecryptionWithNewKey() async throws -> ProfileData? {
        guard let failedDecryptionData = failedDecryptionData else {
            return nil
        }
        
        do {
            _ = try await EncryptionService.shared.initialize()
            
            // Parse the encrypted data (JSON string format)
            guard let encryptedData = failedDecryptionData.data(using: .utf8) else {
                throw ProfileSyncError.invalidDataFormat
            }
            
            let encrypted = try JSONDecoder().decode(EncryptedData.self, from: encryptedData)
            let decryptionResult = try await EncryptionService.shared.decrypt(encrypted, as: ProfileData.self)
            let decrypted = decryptionResult.value
            
            // Cache the successfully decrypted profile
            self.cachedProfile = decrypted
            self.failedDecryptionData = nil
            
            if decryptionResult.usedFallbackKey {
                queueProfileReencryption(for: decrypted, remoteVersion: nil)
            }
            
            
            return decrypted
        } catch {
            return nil
        }
    }
    
    /// Get cached profile (for quick access)
    func getCachedProfile() -> ProfileData? {
        return cachedProfile
    }
    
    /// Clear cache
    func clearCache() {
        cachedProfile = nil
        failedDecryptionData = nil
    }
}

// MARK: - Profile Sync Errors

enum ProfileSyncError: LocalizedError {
    case authenticationRequired
    case invalidResponse
    case fetchFailed(underlying: Error)
    case saveFailed(underlying: Error)
    case invalidDataFormat
    case encryptionFailed
    case decryptionFailed
    case encodingFailed
    case invalidURL
    
    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Authentication required for profile sync"
        case .invalidResponse:
            return "Invalid response from server"
        case .fetchFailed(let underlying):
            return "Failed to fetch profile from cloud: \(underlying.localizedDescription)"
        case .saveFailed(let underlying):
            return "Failed to save profile to cloud: \(underlying.localizedDescription)"
        case .invalidDataFormat:
            return "Invalid data format in profile response"
        case .encryptionFailed:
            return "Failed to encrypt profile data"
        case .decryptionFailed:
            return "Failed to decrypt profile data"
        case .encodingFailed:
            return "Failed to encode data as UTF-8 string"
        case .invalidURL:
            return "Invalid API URL configuration"
        }
    }
}
