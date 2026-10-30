import Foundation
import Security

/// The secret that scopes this device's prompt cache at the model enclaves.
/// The chat service hashes it into the scope the gateway routes model
/// requests by, so nothing the gateway can derive from the caller's
/// credential tells which prompts share a cache. An account keeps its own
/// in the keychain for as long as it is signed in here; a signed-out
/// caller's lasts the app's run, as the caller's chats do.
enum PromptCacheSecret {
    private static let bytes = 32
    private static let lock = NSLock()
    private static var anonymous: String?

    /// The secret, 64 hex characters, or nil when none can be kept or the
    /// kept one cannot be read, in which case the chat service gives each
    /// chat a cache of its own.
    static func secret(userId: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId else {
            if anonymous == nil { anonymous = make() }
            return anonymous
        }
        let key = Constants.Harness.promptCacheSecretKeyPrefix + userId
        let stored: String?
        do {
            stored = try KeychainHelper.shared.loadString(for: key)
        } catch {
            return nil
        }
        if let stored, isSecret(stored) { return stored }
        guard let secret = make(), (try? KeychainHelper.shared.save(secret, for: key)) != nil else { return nil }
        return secret
    }

    /// Forgets an account's secret, as when the account is removed.
    static func forget(userId: String) {
        KeychainHelper.shared.delete(for: Constants.Harness.promptCacheSecretKeyPrefix + userId)
    }

    private static func isSecret(_ text: String) -> Bool {
        text.count == bytes * 2 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func make() -> String? {
        var random = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { return nil }
        return Data(random).hexEncodedString()
    }
}
