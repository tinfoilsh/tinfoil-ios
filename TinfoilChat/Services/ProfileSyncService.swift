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
            let isLoaded = await Clerk.shared.isLoaded
            if !isLoaded {
                try await Clerk.shared.load()
            }
            
            // Get session token
            if let session = await Clerk.shared.session,
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
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProfileSyncError.invalidResponse
        }
        
        if httpResponse.statusCode == 404 {
            return nil
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProfileSyncError.fetchFailed
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
            
            
            let decrypted = try await EncryptionService.shared.decrypt(encrypted, as: ProfileData.self)
            
            // Cache the decrypted profile
            self.cachedProfile = decrypted
            self.failedDecryptionData = nil
            
            
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
        profileWithMetadata.updatedAt = ISO8601DateFormatter().string(from: Date())
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
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ProfileSyncError.saveFailed
        }
        
        // Update cache
        self.cachedProfile = profileWithMetadata
        
        
        return (true, profileWithMetadata.version)
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
            let decrypted = try await EncryptionService.shared.decrypt(encrypted, as: ProfileData.self)
            
            // Cache the successfully decrypted profile
            self.cachedProfile = decrypted
            self.failedDecryptionData = nil
            
            
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
    case fetchFailed
    case saveFailed
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
        case .fetchFailed:
            return "Failed to fetch profile from cloud"
        case .saveFailed:
            return "Failed to save profile to cloud"
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