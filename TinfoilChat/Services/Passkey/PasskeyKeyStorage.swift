//
//  PasskeyKeyStorage.swift
//  TinfoilChat
//
//  Encrypts/decrypts the user's encryption key bundle (primary + alternatives)
//  using a passkey-derived KEK, and stores/retrieves the encrypted blobs via
//  the backend API.
//
//  The backend is a dumb JSONB store — all crypto happens client-side.
//

import CryptoKit
import ClerkKit
import Foundation

// MARK: - Models

/// The plaintext key bundle stored encrypted on the backend.
struct KeyBundle: Codable {
    let primary: String
    let alternatives: [String]
}

/// A single passkey credential entry as stored in the backend JSONB array.
struct PasskeyCredentialEntry: Codable {
    let id: String
    let encrypted_keys: String
    let iv: String
    let created_at: String
}

// MARK: - PasskeyKeyStorage

/// Handles encryption/decryption of key bundles and backend API communication.
final class PasskeyKeyStorage {
    static let shared = PasskeyKeyStorage()

    private let apiBaseURL = Constants.API.baseURL

    private init() {}

    // MARK: - Encrypt / Decrypt

    /// Encrypt a key bundle with an AES-256-GCM KEK.
    /// Returns base64-encoded IV and ciphertext (standard base64, not base64url).
    func encryptKeyBundle(
        kek: SymmetricKey,
        keys: KeyBundle
    ) throws -> (iv: String, data: String) {
        let plaintext = try JSONEncoder().encode(keys)
        let sealedBox = try AES.GCM.seal(plaintext, using: kek)

        // sealedBox.nonce is the 12-byte IV, sealedBox.ciphertext + tag is the rest
        guard let combined = sealedBox.combined else {
            throw PasskeyKeyStorageError.encryptionFailed
        }

        // Split combined: first 12 bytes = nonce, rest = ciphertext + tag
        let nonce = combined.prefix(12)
        let ciphertextAndTag = combined.dropFirst(12)

        return (
            iv: Data(nonce).base64EncodedString(),
            data: Data(ciphertextAndTag).base64EncodedString()
        )
    }

    /// Decrypt a key bundle from base64-encoded IV and ciphertext.
    func decryptKeyBundle(
        kek: SymmetricKey,
        iv: String,
        data: String
    ) throws -> KeyBundle {
        guard let ivData = Data(base64Encoded: iv),
              let ciphertextAndTag = Data(base64Encoded: data) else {
            throw PasskeyKeyStorageError.invalidBase64
        }

        let sealedBox = try AES.GCM.SealedBox(combined: ivData + ciphertextAndTag)
        let plaintext = try AES.GCM.open(sealedBox, using: kek)

        let bundle = try JSONDecoder().decode(KeyBundle.self, from: plaintext)

        guard !bundle.primary.isEmpty else {
            throw PasskeyKeyStorageError.invalidKeyBundle
        }

        return bundle
    }

    // MARK: - Backend API

    /// Load all passkey credential entries for the authenticated user.
    func loadCredentials() async throws -> [PasskeyCredentialEntry] {
        let headers = try await getHeaders()
        let url = URL(string: "\(apiBaseURL)\(Constants.Passkey.credentialsEndpoint)")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PasskeyKeyStorageError.networkError
        }

        if httpResponse.statusCode == 404 {
            return []
        }

        guard httpResponse.statusCode == 200 else {
            throw PasskeyKeyStorageError.apiError(statusCode: httpResponse.statusCode)
        }

        // The backend may return null/empty for users with no credentials
        if data.isEmpty {
            return []
        }

        let decoded = try JSONDecoder().decode(
            PasskeyCredentialsResponse.self,
            from: data
        )
        return decoded.credentials ?? []
    }

    /// Save the full array of passkey credential entries for the authenticated user.
    /// The backend overwrites the entire JSONB column — the client owns the structure.
    func saveCredentials(_ entries: [PasskeyCredentialEntry]) async throws {
        let headers = try await getHeaders()
        let url = URL(string: "\(apiBaseURL)\(Constants.Passkey.credentialsEndpoint)")!

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONEncoder().encode(entries)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PasskeyKeyStorageError.saveFailed
        }
    }

    /// Check if any passkey credentials exist for the authenticated user.
    func hasCredentials() async -> Bool {
        do {
            let entries = try await loadCredentials()
            return !entries.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - High-Level Operations

    /// Encrypt the key bundle and upsert a credential entry, then save to backend.
    /// If a credential with the same ID already exists, it is replaced.
    func storeEncryptedKeys(
        credentialId: String,
        kek: SymmetricKey,
        keys: KeyBundle
    ) async throws {
        let encrypted = try encryptKeyBundle(kek: kek, keys: keys)

        let existing = (try? await loadCredentials()) ?? []
        let previous = existing.first { $0.id == credentialId }

        let entry = PasskeyCredentialEntry(
            id: credentialId,
            encrypted_keys: encrypted.data,
            iv: encrypted.iv,
            created_at: previous?.created_at ?? ISO8601DateFormatter().string(from: Date())
        )

        var updated = existing.filter { $0.id != credentialId }
        updated.append(entry)

        try await saveCredentials(updated)
    }

    /// Decrypt the key bundle for a specific credential entry.
    func retrieveEncryptedKeys(
        credentialId: String,
        kek: SymmetricKey
    ) async throws -> KeyBundle? {
        let entries = try await loadCredentials()
        guard let entry = entries.first(where: { $0.id == credentialId }) else {
            return nil
        }

        return try decryptKeyBundle(kek: kek, iv: entry.iv, data: entry.encrypted_keys)
    }

    /// Get all credential IDs (for attempting recovery with any available credential).
    func allCredentialIds() async -> [String] {
        do {
            let entries = try await loadCredentials()
            return entries.map(\.id)
        } catch {
            return []
        }
    }

    // MARK: - Private Helpers

    private func getHeaders() async throws -> [String: String] {
        guard let session = await Clerk.shared.session,
              let token = try? await session.getToken() else {
            throw PasskeyKeyStorageError.authenticationRequired
        }

        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }
}

// MARK: - Response Model

/// Backend response wrapper for GET /api/passkey-credentials/
private struct PasskeyCredentialsResponse: Decodable {
    let credentials: [PasskeyCredentialEntry]?
}

// MARK: - Errors

enum PasskeyKeyStorageError: LocalizedError {
    case encryptionFailed
    case invalidBase64
    case invalidKeyBundle
    case networkError
    case apiError(statusCode: Int)
    case saveFailed
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt key bundle"
        case .invalidBase64:
            return "Invalid base64 encoding in credential data"
        case .invalidKeyBundle:
            return "Invalid key bundle structure"
        case .networkError:
            return "Network error communicating with backend"
        case .apiError(let statusCode):
            return "Backend API error (status \(statusCode))"
        case .saveFailed:
            return "Failed to save passkey credentials"
        case .authenticationRequired:
            return "Authentication required for passkey operations"
        }
    }
}
