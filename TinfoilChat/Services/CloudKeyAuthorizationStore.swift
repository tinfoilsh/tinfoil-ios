import ClerkKit
import CryptoKit
import Foundation

enum CloudKeyAuthorizationMode: String, Codable {
    case validated
    case explicitStartFresh
}

private struct CloudKeyAuthorizationRecord: Codable {
    let fingerprint: String
    let mode: CloudKeyAuthorizationMode
}

@MainActor
final class CloudKeyAuthorizationStore {
    static let shared = CloudKeyAuthorizationStore()

    private init() {}

    func currentMode(userId: String? = nil) -> CloudKeyAuthorizationMode? {
        guard let resolvedUserId = resolveUserId(userId),
              let record = loadRecord(userId: resolvedUserId),
              let currentFingerprint = currentPrimaryKeyFingerprint(),
              record.fingerprint == currentFingerprint else {
            return nil
        }

        return record.mode
    }

    func hasAuthorizedCurrentPrimaryKey(userId: String? = nil) -> Bool {
        currentMode(userId: userId) != nil
    }

    func authorizeCurrentPrimaryKey(
        mode: CloudKeyAuthorizationMode,
        userId: String? = nil
    ) {
        guard let resolvedUserId = resolveUserId(userId),
              let currentFingerprint = currentPrimaryKeyFingerprint() else {
            return
        }

        let record = CloudKeyAuthorizationRecord(
            fingerprint: currentFingerprint,
            mode: mode
        )

        do {
            let data = try JSONEncoder().encode(record)
            UserDefaults.standard.set(data, forKey: storageKey(userId: resolvedUserId))
        } catch {
            UserDefaults.standard.removeObject(forKey: storageKey(userId: resolvedUserId))
        }
    }

    func clearAuthorization(userId: String? = nil) {
        guard let resolvedUserId = resolveUserId(userId) else { return }
        UserDefaults.standard.removeObject(forKey: storageKey(userId: resolvedUserId))
    }

    private func resolveUserId(_ userId: String?) -> String? {
        userId ?? Clerk.shared.user?.id
    }

    private func storageKey(userId: String) -> String {
        Constants.StorageKeys.Secret.cloudKeyAuthorization(userId: userId)
    }

    private func loadRecord(userId: String) -> CloudKeyAuthorizationRecord? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(userId: userId)) else {
            return nil
        }

        return try? JSONDecoder().decode(CloudKeyAuthorizationRecord.self, from: data)
    }

    private func currentPrimaryKeyFingerprint() -> String? {
        guard let key = EncryptionService.shared.getKey() else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
