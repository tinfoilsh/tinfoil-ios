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

    /// Fields from the last fetched profile that this client does not
    /// model, carried forward on every push so we never wipe settings
    /// owned by another client.
    private var unknownRemoteFields: [String: Any] = [:]

    /// Top-level keys this client models. The profile is a single
    /// full-replace blob shared across clients, so anything else in a
    /// fetched profile belongs to a newer or other-platform client and
    /// must survive our next push rather than being dropped when we
    /// re-serialize only the keys we know about.
    private static let knownProfileKeys: Set<String> = [
        "isDarkMode", "themeMode", "language", "nickname", "profession",
        "traits", "additionalContext", "isUsingPersonalization",
        "isUsingCustomPrompt", "customSystemPrompt", "customPromptPresets",
        "favoritePromptPresetIds", "selectedModel", "reasoningEffort",
        "thinkingEnabled", "webSearchEnabled", "codeExecutionEnabled",
        "piiCheckEnabled", "genUIEnabled", "chatFont", "projectUploadPreference",
        "version", "updatedAt",
    ]

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    // MARK: - Configuration

    /// Set the token getter function for authentication. Wires the
    /// same closure into the shared sync enclave client. Returns once
    /// the actor-isolated client has accepted the getter so callers
    /// can't race the first authenticated request against an empty
    /// token cache.
    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) async {
        self.getToken = tokenGetter
        let captured = tokenGetter
        await SyncEnclaveClient.shared.setTokenGetter { await captured() }
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
            guard let item = response.items.first else {
                // An empty response means no row exists server-side,
                // same as an explicit notFound: clear any stale
                // decrypt-failure state so future uploads aren't
                // wedged by `hasFailedRemoteDecryption()`.
                self.failedDecryptionData = nil
                self.cachedProfile = nil
                self.unknownRemoteFields = [:]
                return nil
            }
            if !item.ok {
                if item.code == WireCodes.notFound {
                    // The row no longer exists server-side; any
                    // prior decrypt-failure state is stale and would
                    // wedge future syncs that consult
                    // `hasFailedRemoteDecryption()`.
                    self.failedDecryptionData = nil
                    self.cachedProfile = nil
                    self.unknownRemoteFields = [:]
                    return nil
                }
                self.failedDecryptionData = "code:\(item.code ?? "UNKNOWN")"
                self.cachedProfile = nil
                return nil
            }
            guard let b64 = item.plaintext,
                  let plaintext = Data(base64Encoded: b64) else {
                return nil
            }
            var decoded = try JSONDecoder().decode(ProfileData.self, from: plaintext)
            // Capture fields we do not model so a later push carries
            // them forward instead of wiping them.
            if let raw = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] {
                self.unknownRemoteFields = raw.filter { !Self.knownProfileKeys.contains($0.key) }
            } else {
                self.unknownRemoteFields = [:]
            }
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
    func saveProfile(_ profile: ProfileData) async throws -> (success: Bool, version: Int?, remoteProfile: ProfileData?) {
        guard await isAuthenticated() else { return (false, nil, nil) }
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()

        // Push the local profile under a given base version. The
        // controlplane treats a missing/zero version as create-only and
        // any positive version as a CAS update gated on the row's etag.
        func pushAtVersion(_ baseVersion: Int) async throws -> (success: Bool, version: Int?) {
            var profileWithMetadata = profile
            // Preserve the caller's edit time so other devices can
            // arbitrate last-write-wins; only stamp now when absent.
            profileWithMetadata.updatedAt = profile.updatedAt ?? Self.iso8601Formatter.string(from: Date())
            profileWithMetadata.version = baseVersion + 1

            let plaintext = try self.encodeProfilePayload(profileWithMetadata)
            let ifMatch: String? = baseVersion > 0 ? String(baseVersion) : nil

            let metadata: [String: AnyCodable] = [
                "version": AnyCodable(profileWithMetadata.version ?? 1)
            ]
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
        }

        do {
            let result = try await pushAtVersion(profile.version ?? 0)
            return (result.success, result.version, nil)
        } catch let error as SyncEnclaveError where Self.isStaleBlobConflict(error) {
            // Optimistic-concurrency conflict: the server holds a
            // version our push was not based on. Re-read it and
            // arbitrate last-write-wins by content modification time.
            let remote = try await fetchProfile()

            if let remote = remote,
               SyncConflictResolver.remoteWins(
                   local: Self.parseISODate(profile.updatedAt),
                   remote: Self.parseISODate(remote.updatedAt)
               ) {
                // The remote is the strictly newer write. Adopt it
                // instead of clobbering, and hand it back so the caller
                // can apply it locally; both devices then converge.
                self.cachedProfile = remote
                return (true, remote.version, remote)
            }

            // Our local edit is the last write. Rebase onto the
            // server's current version and re-push so local wins
            // instead of looping on STALE_BLOB forever.
            let result = try await pushAtVersion(remote?.version ?? 0)
            return (result.success, result.version, nil)
        }
    }

    /// Encode a profile for upload, merging back any fields this client
    /// does not model so a push never drops settings owned by another
    /// client. Known fields always win the merge.
    private func encodeProfilePayload(_ profile: ProfileData) throws -> Data {
        let encoded = try JSONEncoder().encode(profile)
        guard !unknownRemoteFields.isEmpty,
              var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            return encoded
        }
        for (key, value) in unknownRemoteFields where dict[key] == nil {
            dict[key] = value
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// Parse an ISO-8601 timestamp, tolerating values written with or
    /// without fractional seconds so cross-device and cross-client
    /// profiles compare correctly.
    private static func parseISODate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        if let date = iso8601Formatter.date(from: string) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    /// A STALE_BLOB (HTTP 412) push means our If-Match version no longer
    /// matches the server: either the row advanced under another writer
    /// or we tried to create a profile that already exists.
    private static func isStaleBlobConflict(_ error: SyncEnclaveError) -> Bool {
        error.code == WireCodes.staleBlob || error.status == 412
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
        unknownRemoteFields = [:]
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


