//
//  LegacyPasskeyCredentials.swift
//  TinfoilChat
//
//  One-way recovery fetch for passkeys registered on the pre-enclave
//  (v1) webapp. The legacy controlplane stores a client-owned JSONB
//  array of credential entries at /api/passkey-credentials/. iOS
//  consults this endpoint only when the enclave key registry reports
//  no usable bundle for this device, so the recovery flow can still
//  find a passkey to authenticate against and unwrap the user's CEK.
//  After unlock the recovered CEK is promoted into the enclave key
//  registry (see PasskeyKeyFlow.recoverFromLegacyPasskey).
//
//  Writes to this endpoint are intentionally NOT exposed — the legacy
//  table is read-only for the new client. Mirrors the webapp's
//  `services/passkey/legacy-passkey-credentials.ts`.
//

import ClerkKit
import Foundation

/// A single legacy passkey credential as stored in the controlplane's
/// `users.passkey_credentials` JSONB. `iv` and `encryptedKeys` are
/// base64-encoded; the ciphertext is an AES-GCM-wrapped JSON envelope
/// (`{ primary, alternatives }`) under the passkey-PRF-derived KEK.
struct LegacyPasskeyCredentialEntry: Decodable {
    let id: String
    let iv: String
    let encryptedKeys: String
    let createdAt: String?
    let version: Int?
    let syncVersion: Int?
    let bundleVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, iv, version
        case encryptedKeys = "encrypted_keys"
        case createdAt = "created_at"
        case syncVersion = "sync_version"
        case bundleVersion = "bundle_version"
    }
}

enum LegacyPasskeyCredentials {

    /// Fetch the legacy passkey credentials for the authenticated user.
    /// Returns an empty array on any non-success (404/401/network/parse)
    /// so callers can treat "no legacy passkey" and "fetch failed"
    /// identically — both mean the legacy recovery path is unavailable.
    static func fetch() async -> [LegacyPasskeyCredentialEntry] {
        guard let token = await authToken() else { return [] }

        let urlString = "\(Constants.API.baseURL)\(Constants.API.legacyPasskeyCredentialsPath)"
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }
            if http.statusCode == 404 || http.statusCode == 401 { return [] }
            guard (200...299).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode([LegacyPasskeyCredentialEntry].self, from: data)
            return decoded
        } catch {
            return []
        }
    }

    private static func authToken() async -> String? {
        let isLoaded = await Clerk.shared.isLoaded
        if !isLoaded {
            _ = try? await Clerk.shared.refreshClient()
        }
        if let session = await Clerk.shared.session {
            if let token = try? await session.getToken() {
                return token
            }
            if let tokenResource = session.lastActiveToken {
                return tokenResource.jwt
            }
        }
        return nil
    }
}
