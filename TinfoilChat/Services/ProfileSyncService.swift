//
//  ProfileSyncService.swift
//  TinfoilChat
//
//  Profile sync built on top of the attested sync enclave. The
//  enclave is the only encryptor; the controlplane only sees
//  ciphertext from its perspective. Mirrors
//  `services/cloud/profile-sync.ts` in the webapp.
//

import ClerkKit
import Foundation

/// Service for managing profile synchronization with cloud.
@MainActor
class ProfileSyncService: ObservableObject {
    static let shared = ProfileSyncService()

    private let profileScope: SyncScope = .profile
    private let profileRowId = "profile"

    private var getToken: (() async -> String?)? = nil
    private var cachedProfile: ProfileData? = nil
    private var failedDecryptionData: String? = nil

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    // MARK: - Configuration

    /// Set the token getter function for authentication. Wires the
    /// same closure into the shared sync enclave client.
    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) {
        self.getToken = tokenGetter
        let captured = tokenGetter
        Task {
            await SyncEnclaveClient.shared.setTokenGetter { await captured() }
        }
    }

    private func defaultTokenGetter() async -> String? {
        do {
            let isLoaded = Clerk.shared.isLoaded
            if !isLoaded {
                try await Clerk.shared.refreshClient()
            }
            if let session = Clerk.shared.session {
                if let token = try? await session.getToken() {
                    return token
                }
                if let tokenResource = session.lastActiveToken {
                    return tokenResource.jwt
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func isAuthenticated() async -> Bool {
        let token = await (getToken ?? defaultTokenGetter)()
        return token != nil && !token!.isEmpty
    }

    // MARK: - Profile Operations

    /// Get profile from cloud via the sync enclave. The enclave
    /// unseals the row server-side and returns plaintext, so there
    /// is no client-side decryption step.
    func fetchProfile() async throws -> ProfileData? {
        guard await isAuthenticated() else { return nil }
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return nil }

        do {
            let response = try await SyncEnclaveAPI.pull(
                EnclavePullRequest(
                    scope: profileScope,
                    ids: [profileRowId],
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            )
            guard let item = response.items.first else { return nil }
            if !item.ok {
                if item.code == WireCodes.notFound { return nil }
                self.failedDecryptionData = "code:\(item.code ?? "UNKNOWN")"
                self.cachedProfile = nil
                return nil
            }
            guard let b64 = item.plaintext,
                  let plaintext = Data(base64Encoded: b64) else {
                return nil
            }
            var decoded = try JSONDecoder().decode(ProfileData.self, from: plaintext)
            if let etag = item.etag, let version = Int(etag) {
                decoded.version = version
            }
            self.cachedProfile = decoded
            self.failedDecryptionData = nil
            return decoded
        } catch let error as SyncEnclaveError where error.status == 404 {
            return nil
        }
    }

    /// Save profile to cloud through the enclave.
    func saveProfile(_ profile: ProfileData) async throws -> (success: Bool, version: Int?) {
        guard await isAuthenticated() else { return (false, nil) }
        let keyB64: String
        do {
            keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        } catch {
            return (false, nil)
        }

        var profileWithMetadata = profile
        profileWithMetadata.updatedAt = Self.iso8601Formatter.string(from: Date())
        profileWithMetadata.version = (profile.version ?? 0) + 1

        let plaintext = try JSONEncoder().encode(profileWithMetadata)
        let ifMatch: String? = (profile.version ?? 0) > 0 ? String(profile.version!) : nil

        let metadata: [String: AnyCodable] = [
            "version": AnyCodable(profileWithMetadata.version ?? 1)
        ]
        do {
            let response = try await SyncEnclaveAPI.push(
                EnclavePushRequest(
                    scope: profileScope,
                    id: profileRowId,
                    key: keyB64,
                    plaintext: plaintext.base64EncodedString(),
                    ifMatch: ifMatch,
                    idempotencyKey: newSyncEnclaveIdempotencyKey(),
                    metadata: metadata
                )
            )
            if let etagVersion = Int(response.etag) {
                profileWithMetadata.version = etagVersion
            }
            self.cachedProfile = profileWithMetadata
            return (true, profileWithMetadata.version)
        } catch {
            return (false, nil)
        }
    }

    /// Re-attempt a profile fetch after a key change. The enclave
    /// already tries every key the client supplies on each pull, so
    /// a retry is just another pull through the standard path.
    func retryDecryptionWithNewKey() async throws -> ProfileData? {
        guard failedDecryptionData != nil else { return nil }
        return try await fetchProfile()
    }

    func getCachedProfile() -> ProfileData? { cachedProfile }

    func hasFailedRemoteDecryption() -> Bool { failedDecryptionData != nil }

    func clearCache() {
        cachedProfile = nil
        failedDecryptionData = nil
    }

    // MARK: - Sync status

    /// Get sync status to check if the profile changed without
    /// fetching full data. Walks the profile scope's list-status to
    /// look for the singleton row.
    func getSyncStatus() async -> ProfileSyncStatus? {
        guard await isAuthenticated() else { return nil }
        do {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: profileScope,
                    cursor: nil,
                    limit: nil,
                    projectId: nil
                )
            )
            if let current = status.updates.first(where: { $0.id == profileRowId }) {
                let version = Int(current.etag)
                return ProfileSyncStatus(
                    exists: true,
                    version: version,
                    lastUpdated: current.updatedAt
                )
            }
            // No active row — check if it was deleted recently.
            if status.deletes.first(where: { $0.scope == profileScope && $0.id == profileRowId }) != nil {
                return ProfileSyncStatus(exists: false, version: nil, lastUpdated: nil)
            }
            return ProfileSyncStatus(exists: false, version: nil, lastUpdated: nil)
        } catch {
            return nil
        }
    }
}


