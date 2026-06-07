//
//  PasskeyKeyFlow.swift
//  TinfoilChat
//
//  High-level passkey + sync-enclave glue. Mirrors the webapp's
//  `services/sync-enclave/passkey-key-flow.ts`.
//
//  The enclave wire (see `internal/server/types.go`) exposes only
//  `register-key`, `add-bundle`, `remove-bundle` and `current` for
//  key management. There is no "list bundles" endpoint, so this
//  layer's contract is:
//
//    - registerNewKeyWithPasskey: create a passkey, generate a fresh
//      CEK, wrap it under the passkey-PRF KEK, register the key +
//      initial bundle with the enclave. Treats a 409 from the enclave
//      as "remote key already exists, fall through to unlock".
//
//    - unlockWithPasskey: authenticate a passkey, derive the KEK,
//      unwrap a bundle that the caller already has on hand (e.g. one
//      retrieved via `keyCurrent()`).
//
//    - addBundleForCurrentKey: enroll a brand-new passkey for an
//      existing key (multi-device flow).
//
//  The CEK is held only in memory at the call site and zeroed by
//  callers when the session ends.
//

import ClerkKit
import CryptoKit
import Foundation

enum PasskeyFlowFailure: String, Sendable {
    case userCancelled
    case prfUnsupported
    case passkeyTimeout
    case noRemoteBundle
    case noRemoteKey
    case bundleDecryptFailed
    case registerFailed
    case enclaveUnavailable
    case remoteKeyExists
    case keyIdMismatch
}

enum PasskeyFlowResult: Sendable {
    case success(cek: Data, keyIdHex: String, credentialId: String, createdVia: String?)
    case failure(PasskeyFlowFailure, message: String? = nil)
}

struct PasskeyUserInfo {
    let userId: String
    let userEmail: String
    let displayName: String
}

/// `created_via` values accepted by the enclave's `RegisterKey` op.
enum SyncEnclaveCreatedVia: String, Codable, Sendable {
    case passkey
    case manual
    case recovery
    case startFresh = "start_fresh"
}

@MainActor
enum PasskeyKeyFlow {

    // MARK: - Brand-new user: generate + register CEK

    static func registerNewKeyWithPasskey(
        user: PasskeyUserInfo,
        createdVia: SyncEnclaveCreatedVia = .passkey
    ) async -> PasskeyFlowResult {
        var cekBytes = [UInt8](repeating: 0, count: SyncEnclaveKeyBundle.cekByteCount)
        let cekRandomStatus = SecRandomCopyBytes(kSecRandomDefault, cekBytes.count, &cekBytes)
        guard cekRandomStatus == errSecSuccess else {
            return .failure(.registerFailed, message: "Secure random generation failed (status \(cekRandomStatus))")
        }
        return await registerKeyWithPasskey(
            user: user,
            cek: Data(cekBytes),
            createdVia: createdVia
        )
    }

    /// Shared core of the two "register the first CEK + initial
    /// bundle" entry points. Creates the passkey, derives the
    /// key_id, wraps the CEK under the PRF-derived KEK, and calls
    /// `register-key`. The caller decides where the CEK comes from
    /// (freshly generated vs. an existing local one).
    private static func registerKeyWithPasskey(
        user: PasskeyUserInfo,
        cek: Data,
        createdVia: SyncEnclaveCreatedVia
    ) async -> PasskeyFlowResult {
        guard cek.count == SyncEnclaveKeyBundle.cekByteCount else {
            return .failure(.registerFailed, message: "CEK is the wrong size")
        }

        let passkey: PrfPasskeyResult
        do {
            passkey = try await PasskeyService.shared.createPasskey(
                userId: user.userId,
                userEmail: user.userEmail,
                displayName: user.displayName
            )
        } catch let err {
            return .failure(failureFromPasskeyError(err), message: err.localizedDescription)
        }

        let keyIdHex: String
        do {
            keyIdHex = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return .failure(.registerFailed, message: error.localizedDescription)
        }

        let kek = PasskeyService.deriveKeyEncryptionKey(from: passkey.prfOutput)
        let bundle: SyncEnclaveBundleBody
        do {
            bundle = try SyncEnclaveKeyBundle.wrapCek(
                credentialId: passkey.credentialId,
                kek: kek,
                cek: cek
            )
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        do {
            _ = try await SyncEnclaveAPI.registerKey(
                EnclaveKeyRegisterRequest(
                    key: cek.base64EncodedString(),
                    ifMatch: IfMatchSentinels.anyKey,
                    createdVia: createdVia.rawValue,
                    idempotencyKey: newSyncEnclaveIdempotencyKey(),
                    initialBundle: EnclaveKeyRegisterBundleInput(
                        credentialId: bundle.credentialId,
                        kekIvHex: bundle.kekIvHex,
                        encryptedKeysHex: bundle.wrappedKeyHex
                    )
                )
            )
        } catch let err as SyncEnclaveError {
            return .failure(failureFromEnclaveError(err), message: err.message)
        } catch {
            return .failure(.enclaveUnavailable, message: error.localizedDescription)
        }

        return .success(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: passkey.credentialId,
            createdVia: createdVia.rawValue
        )
    }

    // MARK: - Returning user: unlock from server

    /// End-to-end "returning user" unlock against the enclave. Wraps
    /// keyCurrent() + unlockWithPasskey() + the key_id binding check
    /// into a single call.
    static func unlockFromServer(prefer: String? = nil, silent: Bool = false) async -> PasskeyFlowResult {
        let state: EnclaveKeyCurrentResponse
        do {
            state = try await SyncEnclaveAPI.keyCurrent()
        } catch let err as SyncEnclaveError {
            return .failure(failureFromEnclaveError(err), message: err.message)
        } catch {
            return .failure(.enclaveUnavailable, message: error.localizedDescription)
        }

        guard let serverKeyId = state.keyId, !state.bundles.isEmpty else {
            return .failure(.noRemoteKey)
        }

        let candidates = state.bundles.values.sorted { $0.credentialId < $1.credentialId }
        let result = await unlockWithPasskey(candidates: candidates, prefer: prefer, silent: silent)
        guard case .success(let cek, let derivedKeyIdHex, let credentialId, _) = result else {
            return result
        }

        // §8.6 binding check — the bundle plaintext carries the
        // key_id the ciphertext was wrapped against. The enclave's
        // reported key_id MUST match the derived id, or the bundle
        // is talking about a different key.
        guard derivedKeyIdHex == serverKeyId else {
            return .failure(.keyIdMismatch, message: "keyId \(derivedKeyIdHex) != enclave \(serverKeyId)")
        }
        return .success(
            cek: cek,
            keyIdHex: derivedKeyIdHex,
            credentialId: credentialId,
            createdVia: state.createdVia
        )
    }

    /// Recover the user's CEK by re-authenticating their passkey and
    /// unwrapping a candidate bundle. The caller supplies the bundles —
    /// typically from a fresh `keyCurrent()` probe.
    static func unlockWithPasskey(
        candidates: [EnclaveKeyCurrentBundle],
        prefer: String? = nil,
        silent: Bool = false
    ) async -> PasskeyFlowResult {
        guard !candidates.isEmpty else {
            return .failure(.noRemoteBundle)
        }
        let credIds = candidates.map(\.credentialId)
        let ordered: [String]
        if let prefer, credIds.contains(prefer) {
            ordered = [prefer] + credIds.filter { $0 != prefer }
        } else {
            ordered = credIds
        }

        let passkey: PrfPasskeyResult
        do {
            passkey = try await PasskeyService.shared.authenticatePasskey(credentialIds: ordered, silent: silent)
        } catch let err {
            return .failure(failureFromPasskeyError(err), message: err.localizedDescription)
        }

        guard let bundle = candidates.first(where: { $0.credentialId == passkey.credentialId }) else {
            return .failure(.noRemoteBundle)
        }

        let kek = PasskeyService.deriveKeyEncryptionKey(from: passkey.prfOutput)
        let cek: Data
        do {
            cek = try SyncEnclaveKeyBundle.unwrapCek(kek: kek, bundle: bundle)
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        let keyIdHex: String
        do {
            keyIdHex = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        return .success(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: passkey.credentialId,
            createdVia: nil
        )
    }

    // MARK: - First-time backup: register the existing local CEK

    /// Back up an already-local CEK to the enclave by creating a
    /// passkey, wrapping the *existing* CEK under that passkey's
    /// PRF-derived KEK, and calling `register-key` with that bundle.
    /// Used by "Add this device to passkey backup" when the enclave
    /// has no key yet but the device already has one — generating a
    /// fresh CEK in that case would silently strand every local
    /// chat sealed under the existing key.
    static func registerExistingKeyWithPasskey(
        existingCek: Data,
        user: PasskeyUserInfo,
        createdVia: SyncEnclaveCreatedVia = .recovery
    ) async -> PasskeyFlowResult {
        return await registerKeyWithPasskey(
            user: user,
            cek: existingCek,
            createdVia: createdVia
        )
    }

    // MARK: - Legacy (v1) passkey recovery

    /// Recover the user's CEK from a passkey registered on the
    /// pre-enclave webapp, then promote it into the enclave key
    /// registry so future sessions use the v2 wire.
    ///
    /// The caller passes the legacy credential entries (from
    /// `LegacyPasskeyCredentials.fetch()`) and the enclave's current
    /// key_id (or nil when no `user_keys` row exists yet). The flow:
    ///   1. authenticate one of the legacy passkeys (PRF),
    ///   2. unwrap the AES-GCM legacy bundle under the PRF-derived KEK,
    ///   3. derive the CEK's key_id and reconcile it with the enclave:
    ///      - no enclave key  → register-key with an initial bundle,
    ///      - matching key_id → add a bundle for this credential,
    ///      - mismatched id   → fail (the legacy CEK is a rotated-away
    ///        key; never clobber the current primary).
    static func recoverFromLegacyPasskey(
        entries: [LegacyPasskeyCredentialEntry],
        enclaveKeyId: String?
    ) async -> PasskeyFlowResult {
        guard !entries.isEmpty else {
            return .failure(.noRemoteBundle)
        }

        let credentialIds = entries.map(\.id)
        let passkey: PrfPasskeyResult
        do {
            // Use only locally-available credentials so the system does not
            // surface its cross-device "Use a Device Nearby" QR sheet. When
            // the legacy passkey isn't on this device, this fails fast and we
            // fall through to manual recovery (scan the webapp QR / paste key).
            passkey = try await PasskeyService.shared.authenticatePasskey(
                credentialIds: credentialIds,
                silent: true
            )
        } catch let err {
            return .failure(failureFromPasskeyError(err), message: err.localizedDescription)
        }

        guard let entry = entries.first(where: { $0.id == passkey.credentialId }) else {
            return .failure(.noRemoteBundle)
        }

        guard let ivData = Data(base64Encoded: entry.iv),
              let ciphertextData = Data(base64Encoded: entry.encryptedKeys) else {
            return .failure(.bundleDecryptFailed, message: "Legacy bundle is not valid base64")
        }

        let kek = PasskeyService.deriveKeyEncryptionKey(from: passkey.prfOutput)
        let cek: Data
        do {
            cek = try SyncEnclaveKeyBundle.unwrapCek(
                kek: kek,
                kekIvHex: dataToHex(ivData),
                wrappedKeyHex: dataToHex(ciphertextData)
            )
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        let keyIdHex: String
        do {
            keyIdHex = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        // The legacy CEK must match the enclave's current primary key
        // (when one exists) before we treat it as a recovery — adopting
        // a rotated-away key as primary would strand the live data.
        if let enclaveKeyId, keyIdHex != enclaveKeyId {
            return .failure(.keyIdMismatch, message: "legacy keyId \(keyIdHex) != enclave \(enclaveKeyId)")
        }

        let bundle: SyncEnclaveBundleBody
        do {
            bundle = try SyncEnclaveKeyBundle.wrapCek(
                credentialId: passkey.credentialId,
                kek: kek,
                cek: cek
            )
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        if enclaveKeyId == nil {
            // No enclave key yet — register the recovered CEK + initial
            // bundle so the user becomes a first-class v2 user.
            do {
                _ = try await SyncEnclaveAPI.registerKey(
                    EnclaveKeyRegisterRequest(
                        key: dataToBase64(cek),
                        ifMatch: IfMatchSentinels.anyKey,
                        createdVia: SyncEnclaveCreatedVia.recovery.rawValue,
                        idempotencyKey: newSyncEnclaveIdempotencyKey(),
                        initialBundle: EnclaveKeyRegisterBundleInput(
                            credentialId: bundle.credentialId,
                            kekIvHex: bundle.kekIvHex,
                            encryptedKeysHex: bundle.wrappedKeyHex
                        )
                    )
                )
            } catch let err as SyncEnclaveError {
                // A racing setup may have landed first; the caller can
                // re-run recovery against whatever the enclave now reports.
                return .failure(failureFromEnclaveError(err), message: err.message)
            } catch {
                return .failure(.enclaveUnavailable, message: error.localizedDescription)
            }
        } else {
            // Enclave key matches the recovered CEK but this credential
            // has no bundle yet — add one so subsequent sessions unlock
            // via the v2 wire instead of falling back to legacy. A
            // failure here is non-fatal: the user is already unlocked
            // locally and will simply hit the legacy path again next time.
            do {
                _ = try await SyncEnclaveAPI.addBundle(
                    EnclaveAddBundleRequest(
                        keyId: keyIdHex,
                        key: dataToBase64(cek),
                        credentialId: bundle.credentialId,
                        kekIvHex: bundle.kekIvHex,
                        encryptedKeysHex: bundle.wrappedKeyHex,
                        idempotencyKey: newSyncEnclaveIdempotencyKey()
                    )
                )
            } catch {
                // Non-fatal — the CEK is already recovered locally.
            }
        }

        return .success(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: passkey.credentialId,
            createdVia: SyncEnclaveCreatedVia.recovery.rawValue
        )
    }

    // MARK: - Multi-device: enroll new passkey for current CEK

    static func addBundleForCurrentKey(
        cek: Data,
        keyIdHex: String,
        user: PasskeyUserInfo
    ) async -> PasskeyFlowResult {
        let passkey: PrfPasskeyResult
        do {
            passkey = try await PasskeyService.shared.createPasskey(
                userId: user.userId,
                userEmail: user.userEmail,
                displayName: user.displayName
            )
        } catch let err {
            return .failure(failureFromPasskeyError(err), message: err.localizedDescription)
        }

        let kek = PasskeyService.deriveKeyEncryptionKey(from: passkey.prfOutput)
        let bundle: SyncEnclaveBundleBody
        do {
            bundle = try SyncEnclaveKeyBundle.wrapCek(
                credentialId: passkey.credentialId,
                kek: kek,
                cek: cek
            )
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        do {
            _ = try await SyncEnclaveAPI.addBundle(
                EnclaveAddBundleRequest(
                    keyId: keyIdHex,
                    key: cek.base64EncodedString(),
                    credentialId: bundle.credentialId,
                    kekIvHex: bundle.kekIvHex,
                    encryptedKeysHex: bundle.wrappedKeyHex,
                    idempotencyKey: newSyncEnclaveIdempotencyKey()
                )
            )
        } catch let err as SyncEnclaveError {
            return .failure(failureFromEnclaveError(err), message: err.message)
        } catch {
            return .failure(.enclaveUnavailable, message: error.localizedDescription)
        }

        return .success(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: passkey.credentialId,
            createdVia: nil
        )
    }

    /// Revoke a passkey bundle from the current key. Caller still
    /// holds the CEK locally so cloud reads/writes keep working from
    /// other enrolled passkeys. Throws on enclave error so callers
    /// can react to the specific failure (network, auth, no such
    /// bundle, etc.) instead of a yes/no signal.
    static func removeBundleFromCurrentKey(
        cek: Data,
        keyIdHex: String,
        credentialId: String
    ) async throws {
        _ = try await SyncEnclaveAPI.removeBundle(
            EnclaveRemoveBundleRequest(
                keyId: keyIdHex,
                key: cek.base64EncodedString(),
                credentialId: credentialId,
                idempotencyKey: newSyncEnclaveIdempotencyKey()
            )
        )
    }

    // MARK: - Mapping

    private static func failureFromPasskeyError(_ err: Error) -> PasskeyFlowFailure {
        if let passkeyError = err as? PasskeyError {
            switch passkeyError {
            case .prfNotSupported, .prfOutputMissing:
                return .prfUnsupported
            case .userCancelled:
                return .userCancelled
            case .authorizationFailed, .randomGenerationFailed, .invalidBase64url:
                return .userCancelled
            }
        }
        return .userCancelled
    }

    private static func failureFromEnclaveError(_ err: SyncEnclaveError) -> PasskeyFlowFailure {
        if err.code == WireCodes.existingDataUnderOtherKey || err.status == 409 {
            return .remoteKeyExists
        }
        if let status = err.status, status >= 500 {
            return .enclaveUnavailable
        }
        if err.code == WireCodes.attestationFailed {
            return .enclaveUnavailable
        }
        if err.code == WireCodes.network {
            return .enclaveUnavailable
        }
        return .registerFailed
    }
}
