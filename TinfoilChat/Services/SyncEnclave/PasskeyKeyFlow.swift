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
//    - unlockFromServer: authenticate a passkey against the bundles
//      reported by `keyCurrent()`, derive the KEK, unwrap the bundle,
//      and verify the key_id binding before adopting anything.
//
//    - addBundleForCurrentKey: enroll a brand-new passkey for an
//      existing key (multi-device flow).
//
//  The CEK is held only in memory at the call site and zeroed by
//  callers when the session ends.
//

import ClerkKit
import Foundation
import Security
import TinfoilPasskeyKit

enum PasskeyFlowFailure: String, Sendable {
    case userCancelled
    case prfUnsupported
    case timedOut
    case noRemoteBundle
    case noRemoteKey
    case bundleDecryptFailed
    case registerFailed
    case enclaveUnavailable
    case presentationUnavailable
    case remoteKeyExists
    case keyIdMismatch
}

enum PasskeyFlowResult: Sendable {
    case success(cek: Data, keyIdHex: String, credentialId: String, createdVia: String?)
    case failure(PasskeyFlowFailure, message: String? = nil)
}

struct LegacyPasskeyPromotion: Sendable {
    let expectedEnclaveKeyId: String?
    let keyB64: String
    let credentialId: String
    let kekIvHex: String
    let encryptedKeysHex: String
}

struct LegacyPasskeyRecovery: Sendable {
    let cek: Data
    let keyIdHex: String
    let credentialId: String
    let legacyAlternatives: [String]
    let promotion: LegacyPasskeyPromotion

    var flowResult: PasskeyFlowResult {
        .success(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: credentialId,
            createdVia: SyncEnclaveCreatedVia.recovery.rawValue
        )
    }
}

enum LegacyPasskeyRecoveryResult: Sendable {
    case success(LegacyPasskeyRecovery)
    case failure(PasskeyFlowFailure, message: String? = nil)
}

enum PasskeyCandidateRecoveryResult: Sendable {
    case current(PasskeyFlowResult, legacyAlternatives: [String])
    case legacy(LegacyPasskeyRecovery)
    case failure(PasskeyFlowFailure, message: String? = nil)
}

struct PasskeyRecoveryCandidates {
    let current: TinfoilWrappedKeyAdapter.CandidateSet
    let legacy: [LegacyPasskeyCredentialEntry]
    let credentialIds: [String]

    init(
        bundles: [EnclaveKeyCurrentBundle],
        legacy: [LegacyPasskeyCredentialEntry],
        preferredCredentialId: String?
    ) {
        current = TinfoilWrappedKeyAdapter.partition(
            bundles,
            preferredCredentialId: preferredCredentialId
        )
        self.legacy = legacy

        var seen = Set<String>()
        var ordered = (current.credentialIds + legacy.map(\.id)).filter { seen.insert($0).inserted }
        if let preferredCredentialId,
           let preferredIndex = ordered.firstIndex(of: preferredCredentialId) {
            ordered.insert(ordered.remove(at: preferredIndex), at: 0)
        }
        credentialIds = ordered
    }

    func resolveSelectedCredential<Result>(
        credentialId: String,
        current recoverCurrent: (TinfoilWrappedKeyAdapter.CandidateSet.Current) -> Result?,
        currentEnvelope recoverCurrentEnvelope: (EnclaveKeyCurrentBundle) -> Result?,
        legacy recoverLegacy: (LegacyPasskeyCredentialEntry) -> Result?
    ) -> Result? {
        for candidate in current.current where candidate.bundle.credentialId == credentialId {
            if let result = recoverCurrent(candidate) { return result }
        }
        for bundle in current.legacy where bundle.credentialId == credentialId {
            if let result = recoverCurrentEnvelope(bundle) { return result }
        }
        for entry in legacy where entry.id == credentialId {
            if let result = recoverLegacy(entry) { return result }
        }
        return nil
    }
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
        let cek: Data
        do {
            cek = try generateCek()
        } catch {
            return .failure(.registerFailed, message: error.localizedDescription)
        }
        let result = await registerKeyWithPasskey(
            user: user,
            cek: cek,
            createdVia: createdVia
        )
        // A 409 means another device won the register race, so the
        // documented contract is to fall through to a normal unlock
        // against whichever key landed (its passkey may already be in
        // this device's iCloud Keychain). Start-fresh is excluded: the
        // user explicitly asked to replace the remote key, and silently
        // adopting it instead would betray that intent.
        if createdVia != .startFresh,
           case .failure(.remoteKeyExists, _) = result {
            return await unlockFromServer()
        }
        return result
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

        let created: CreatedWrappedKey
        do {
            created = try await PasskeyService.shared.createAndWrapKey(
                userId: user.userId,
                userEmail: user.userEmail,
                displayName: user.displayName,
                key: cek
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

        let bundle = TinfoilWrappedKeyAdapter.bundleBody(created.wrappedKey)

        // `If-Match: *` is create-only: the controlplane rejects it
        // whenever a key row already exists. A start-fresh over an
        // existing key must instead CAS on the current etag so the
        // wipe-and-replace lands (the recovery chooser shows the
        // start-fresh option precisely when a key is registered).
        var ifMatch = IfMatchSentinels.anyKey
        if createdVia == .startFresh {
            do {
                let current = try await SyncEnclaveAPI.keyCurrent()
                if current.keyId != nil, let etag = current.etag {
                    ifMatch = etag
                }
            } catch {
                // Fall through with '*': correct for the no-key case,
                // and fails closed (409) when a key actually exists.
            }
        }

        do {
            _ = try await SyncEnclaveAPI.registerKey(
                EnclaveKeyRegisterRequest(
                    key: cek.base64EncodedString(),
                    ifMatch: ifMatch,
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
            credentialId: created.credentialId,
            createdVia: createdVia.rawValue
        )
    }

    // MARK: - Returning user: unlock from server

    /// End-to-end "returning user" unlock against the enclave. Wraps
    /// keyCurrent() + unlockWithPasskeyDetailed() + the key_id binding check
    /// into a single call.
    static func unlockFromServer(prefer: String? = nil, silent: Bool = false) async -> PasskeyFlowResult {
        let state: EnclaveKeyCurrentResponse
        do {
            state = try await SyncEnclaveAPI.keyCurrent()
        } catch let err as SyncEnclaveError {
            PasskeyDiagnostics.failure("unlock: keyCurrent failed: \(err.message)")
            return .failure(failureFromEnclaveError(err), message: err.message)
        } catch {
            PasskeyDiagnostics.failure("unlock: keyCurrent failed: \(error.localizedDescription)")
            return .failure(.enclaveUnavailable, message: error.localizedDescription)
        }

        guard let serverKeyId = state.keyId, !state.bundles.isEmpty else {
            PasskeyDiagnostics.failure(
                "unlock: no remote key or bundles "
                + "(keyId=\(PasskeyDiagnostics.keyIdPrefix(state.keyId)) bundles=\(state.bundles.count))"
            )
            return .failure(.noRemoteKey)
        }

        let candidates = state.bundles.values.sorted { $0.credentialId < $1.credentialId }
        let (result, legacyAlternatives) = await unlockWithPasskeyDetailed(
            candidates: candidates,
            prefer: prefer,
            silent: silent
        )
        guard case .success(let cek, let derivedKeyIdHex, let credentialId, _) = result else {
            if case .failure(let failure, let message) = result {
                PasskeyDiagnostics.failure(
                    "unlock: failed (\(failure.rawValue)): \(message ?? "-")"
                )
            }
            return result
        }

        // §8.6 binding check — the bundle plaintext carries the
        // key_id the ciphertext was wrapped against. The enclave's
        // reported key_id MUST match the derived id, or the bundle
        // is talking about a different key.
        guard derivedKeyIdHex == serverKeyId else {
            PasskeyDiagnostics.failure(
                "unlock: key id mismatch derived=\(PasskeyDiagnostics.keyIdPrefix(derivedKeyIdHex)) "
                + "enclave=\(PasskeyDiagnostics.keyIdPrefix(serverKeyId))"
            )
            return .failure(.keyIdMismatch, message: "keyId \(derivedKeyIdHex) != enclave \(serverKeyId)")
        }
        // Adopt the bundle's legacy alternatives only after the binding
        // check accepts it: a rejected bundle must not mutate the local
        // key history.
        retainLegacyAlternatives(legacyAlternatives)
        return .success(
            cek: cek,
            keyIdHex: derivedKeyIdHex,
            credentialId: credentialId,
            createdVia: state.createdVia
        )
    }

    static func recoverFromCurrentAndLegacy(
        state: EnclaveKeyCurrentResponse,
        legacyEntries: [LegacyPasskeyCredentialEntry],
        prefer: String?,
        immediatelyAvailable: Bool
    ) async -> PasskeyCandidateRecoveryResult {
        let candidates = PasskeyRecoveryCandidates(
            bundles: state.bundles.values.sorted { $0.credentialId < $1.credentialId },
            legacy: legacyEntries,
            preferredCredentialId: prefer
        )
        PasskeyDiagnostics.step(
            "recovery: keyId=\(PasskeyDiagnostics.keyIdPrefix(state.keyId)) "
            + "bundles=\(state.bundles.count) legacy=\(legacyEntries.count) "
            + "candidates=\(candidates.credentialIds.count) "
            + "preferKnown=\(prefer != nil) silent=\(immediatelyAvailable)"
        )
        guard !candidates.credentialIds.isEmpty else {
            PasskeyDiagnostics.failure("recovery: no candidate credentials")
            return .failure(.noRemoteBundle)
        }

        let evaluated: EvaluatedCredential
        do {
            evaluated = try await PasskeyService.shared.evaluateCredential(
                credentialIds: candidates.credentialIds,
                preferredCredentialId: prefer,
                immediatelyAvailable: immediatelyAvailable
            )
        } catch let err {
            let failure = failureFromPasskeyError(err)
            PasskeyDiagnostics.failure(
                "recovery: ceremony failed (\(failure.rawValue)): \(PasskeyDiagnostics.describe(err))"
            )
            return .failure(failure, message: err.localizedDescription)
        }
        PasskeyDiagnostics.step("recovery: ceremony succeeded, resolving asserted credential")

        var externalLegacyFailure: PasskeyCandidateRecoveryResult?
        if let resolved: PasskeyCandidateRecoveryResult = candidates.resolveSelectedCredential(
            credentialId: evaluated.credentialId,
            current: { candidate in
                let cek: Data
                do {
                    cek = try PasskeyService.shared.unwrapKeyWithPRFResult(
                        wrappedKey: candidate.wrappedKey,
                        prfResult: evaluated.prfResult
                    )
                } catch {
                    PasskeyDiagnostics.failure(
                        "recovery: bundle unwrap failed: \(PasskeyDiagnostics.describe(error))"
                    )
                    return nil
                }
                guard let keyIdHex = try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek) else {
                    PasskeyDiagnostics.failure("recovery: key id derivation failed")
                    return nil
                }
                guard keyIdHex == state.keyId else {
                    PasskeyDiagnostics.failure(
                        "recovery: key id mismatch derived=\(PasskeyDiagnostics.keyIdPrefix(keyIdHex)) "
                        + "enclave=\(PasskeyDiagnostics.keyIdPrefix(state.keyId))"
                    )
                    return nil
                }
                return .current(.success(
                    cek: cek,
                    keyIdHex: keyIdHex,
                    credentialId: evaluated.credentialId,
                    createdVia: state.createdVia
                ), legacyAlternatives: [])
            },
            currentEnvelope: { bundle in
                let unwrapped: SyncEnclaveUnwrappedCek
                do {
                    unwrapped = try SyncEnclaveKeyBundle.unwrapLegacyJsonEnvelope(
                        prfOutput: evaluated.prfResult.output,
                        kekIvHex: bundle.kekIv,
                        wrappedKeyHex: bundle.encryptedKeys
                    )
                } catch {
                    PasskeyDiagnostics.failure(
                        "recovery: envelope unwrap failed: \(PasskeyDiagnostics.describe(error))"
                    )
                    return nil
                }
                guard let keyIdHex = try? SyncEnclaveKeyBundle.deriveKeyIdHex(cek: unwrapped.cek) else {
                    PasskeyDiagnostics.failure("recovery: envelope key id derivation failed")
                    return nil
                }
                guard keyIdHex == state.keyId else {
                    PasskeyDiagnostics.failure(
                        "recovery: envelope key id mismatch derived=\(PasskeyDiagnostics.keyIdPrefix(keyIdHex)) "
                        + "enclave=\(PasskeyDiagnostics.keyIdPrefix(state.keyId))"
                    )
                    return nil
                }
                return .current(.success(
                    cek: unwrapped.cek,
                    keyIdHex: keyIdHex,
                    credentialId: evaluated.credentialId,
                    createdVia: state.createdVia
                ), legacyAlternatives: unwrapped.legacyAlternativeKeys)
            },
            legacy: { entry in
                let result = recoverLegacyEntry(
                    entry,
                    evaluated: evaluated,
                    enclaveKeyId: state.keyId
                )
                if case .legacy = result { return result }
                if case .failure(let failure, let message) = result {
                    PasskeyDiagnostics.failure(
                        "recovery: legacy entry failed (\(failure.rawValue)): \(message ?? "-")"
                    )
                }
                externalLegacyFailure = preferredExternalLegacyFailure(
                    externalLegacyFailure,
                    over: result
                )
                return nil
            }
        ) {
            return resolved
        }

        if externalLegacyFailure == nil {
            PasskeyDiagnostics.failure(
                "recovery: asserted credential resolved no usable bundle"
            )
        }
        return externalLegacyFailure ?? .failure(.bundleDecryptFailed)
    }

    static func preferredExternalLegacyFailure(
        _ current: PasskeyCandidateRecoveryResult?,
        over candidate: PasskeyCandidateRecoveryResult
    ) -> PasskeyCandidateRecoveryResult? {
        guard case .failure(let candidateFailure, _) = candidate else { return current }
        guard let current else { return candidate }
        guard case .failure(let currentFailure, _) = current else { return candidate }
        if candidateFailure == .keyIdMismatch && currentFailure != .keyIdMismatch {
            return candidate
        }
        return current
    }

    /// Recover the user's CEK by re-authenticating their passkey and
    /// unwrapping a candidate bundle. The caller supplies the bundles —
    /// typically from a fresh `keyCurrent()` probe. Legacy alternative
    /// keys found in the bundle envelope are returned, not retained:
    /// the caller decides after its own validation (e.g. the key_id
    /// binding check) whether they may enter the local key history.
    private static func unlockWithPasskeyDetailed(
        candidates: [EnclaveKeyCurrentBundle],
        prefer: String? = nil,
        silent: Bool = false
    ) async -> (PasskeyFlowResult, legacyAlternatives: [String]) {
        guard !candidates.isEmpty else {
            return (.failure(.noRemoteBundle), [])
        }
        let candidateSet = TinfoilWrappedKeyAdapter.partition(
            candidates,
            preferredCredentialId: prefer
        )
        let credentialId: String
        let cek: Data
        var legacyAlternatives: [String] = []

        if candidateSet.legacy.isEmpty {
            guard !candidateSet.current.isEmpty else {
                return (.failure(.noRemoteBundle), [])
            }
            do {
                let recovered = try await PasskeyService.shared.recoverKey(
                    wrappedKeys: candidateSet.current.map(\.wrappedKey),
                    preferredCredentialId: prefer,
                    immediatelyAvailable: silent
                )
                credentialId = recovered.credentialId
                cek = recovered.key
            } catch let err {
                return (.failure(failureFromPasskeyError(err), message: err.localizedDescription), [])
            }
        } else {
            let evaluated: EvaluatedCredential
            do {
                evaluated = try await PasskeyService.shared.evaluateCredential(
                    credentialIds: candidateSet.credentialIds,
                    preferredCredentialId: prefer,
                    immediatelyAvailable: silent
                )
            } catch let err {
                return (.failure(failureFromPasskeyError(err), message: err.localizedDescription), [])
            }

            switch candidateSet.selection(credentialId: evaluated.credentialId) {
            case .current(let current):
                do {
                    cek = try PasskeyService.shared.unwrapKeyWithPRFResult(
                        wrappedKey: current.wrappedKey,
                        prfResult: evaluated.prfResult
                    )
                    credentialId = evaluated.credentialId
                } catch let err {
                    return (.failure(failureFromPasskeyError(err), message: err.localizedDescription), [])
                }
            case .legacy(let bundle):
                let unwrapped: SyncEnclaveUnwrappedCek
                do {
                    unwrapped = try SyncEnclaveKeyBundle.unwrapLegacyJsonEnvelope(
                        prfOutput: evaluated.prfResult.output,
                        kekIvHex: bundle.kekIv,
                        wrappedKeyHex: bundle.encryptedKeys
                    )
                } catch {
                    return (.failure(.bundleDecryptFailed, message: error.localizedDescription), [])
                }
                credentialId = evaluated.credentialId
                cek = unwrapped.cek
                legacyAlternatives = unwrapped.legacyAlternativeKeys
            case .missing:
                return (.failure(.noRemoteBundle), [])
            }
        }

        let keyIdHex: String
        do {
            keyIdHex = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)
        } catch {
            return (.failure(.bundleDecryptFailed, message: error.localizedDescription), [])
        }

        return (
            .success(
                cek: cek,
                keyIdHex: keyIdHex,
                credentialId: credentialId,
                createdVia: nil
            ),
            legacyAlternatives
        )
    }

    /// Keep historical CEKs carried by a legacy bundle envelope as
    /// decrypt-only fallbacks so the migration sweep can unseal rows
    /// still sealed under a rotated-away key. Additive and idempotent;
    /// never touches the primary key.
    static func retainLegacyAlternatives(_ keys: [String]) {
        for key in keys {
            try? EncryptionService.shared.addDecryptionKey(key)
        }
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
    /// pre-enclave webapp and return immutable promotion material.
    ///
    /// The caller passes the legacy credential entries (from
    /// `LegacyPasskeyCredentials.fetch()`) and the enclave's current
    /// key_id (or nil when no `user_keys` row exists yet). This method:
    ///   1. authenticate one of the legacy passkeys (PRF),
    ///   2. unwrap the AES-GCM legacy bundle under the PRF-derived KEK,
    ///   3. derive the CEK's key_id and reject a known mismatch,
    ///   4. return the recovered key and wrapped bundle for the manager
    ///      to validate and promote under the current account.
    static func recoverFromLegacyPasskey(
        entries: [LegacyPasskeyCredentialEntry],
        enclaveKeyId: String?
    ) async -> LegacyPasskeyRecoveryResult {
        guard !entries.isEmpty else {
            return .failure(.noRemoteBundle)
        }

        let credentialIds = entries.map(\.id)
        let evaluated: EvaluatedCredential
        do {
            // Use only locally-available credentials so the system does not
            // surface its cross-device "Use a Device Nearby" QR sheet. When
            // the legacy passkey isn't on this device, this fails fast and we
            // fall through to manual recovery (scan the webapp QR / paste key).
            evaluated = try await PasskeyService.shared.evaluateCredential(
                credentialIds: credentialIds,
                preferredCredentialId: nil,
                immediatelyAvailable: true
            )
        } catch let err {
            return .failure(failureFromPasskeyError(err), message: err.localizedDescription)
        }

        guard let entry = entries.first(where: { $0.id == evaluated.credentialId }) else {
            return .failure(.noRemoteBundle)
        }
        switch recoverLegacyEntry(entry, evaluated: evaluated, enclaveKeyId: enclaveKeyId) {
        case .legacy(let recovery):
            return .success(recovery)
        case .failure(let failure, let message):
            return .failure(failure, message: message)
        case .current:
            return .failure(.bundleDecryptFailed)
        }
    }

    private static func recoverLegacyEntry(
        _ entry: LegacyPasskeyCredentialEntry,
        evaluated: EvaluatedCredential,
        enclaveKeyId: String?
    ) -> PasskeyCandidateRecoveryResult {
        guard let ivData = Data(base64Encoded: entry.iv),
              let ciphertextData = Data(base64Encoded: entry.encryptedKeys) else {
            return .failure(.bundleDecryptFailed, message: "Legacy bundle is not valid base64")
        }

        let cek: Data
        let legacyAlternatives: [String]
        do {
            let unwrapped = try SyncEnclaveKeyBundle.unwrapLegacyJsonEnvelope(
                prfOutput: evaluated.prfResult.output,
                kekIvHex: dataToHex(ivData),
                wrappedKeyHex: dataToHex(ciphertextData)
            )
            cek = unwrapped.cek
            legacyAlternatives = unwrapped.legacyAlternativeKeys
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
            let wrapped = try PasskeyService.shared.wrapKeyWithPRFResult(
                key: cek,
                credentialId: evaluated.credentialId,
                prfResult: evaluated.prfResult
            )
            bundle = TinfoilWrappedKeyAdapter.bundleBody(wrapped)
        } catch {
            return .failure(.bundleDecryptFailed, message: error.localizedDescription)
        }

        return .legacy(LegacyPasskeyRecovery(
            cek: cek,
            keyIdHex: keyIdHex,
            credentialId: evaluated.credentialId,
            legacyAlternatives: legacyAlternatives,
            promotion: LegacyPasskeyPromotion(
                expectedEnclaveKeyId: enclaveKeyId,
                keyB64: dataToBase64(cek),
                credentialId: bundle.credentialId,
                kekIvHex: bundle.kekIvHex,
                encryptedKeysHex: bundle.wrappedKeyHex
            )
        ))
    }

    // MARK: - Multi-device: enroll new passkey for current CEK

    static func addBundleForCurrentKey(
        cek: Data,
        keyIdHex: String,
        user: PasskeyUserInfo
    ) async -> PasskeyFlowResult {
        let created: CreatedWrappedKey
        do {
            created = try await PasskeyService.shared.createAndWrapKey(
                userId: user.userId,
                userEmail: user.userEmail,
                displayName: user.displayName,
                key: cek
            )
        } catch let err {
            return .failure(failureFromPasskeyError(err), message: err.localizedDescription)
        }

        let bundle = TinfoilWrappedKeyAdapter.bundleBody(created.wrappedKey)

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
            credentialId: created.credentialId,
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

    static func failureFromPasskeyError(_ err: Error) -> PasskeyFlowFailure {
        if let passkeyError = err as? PasskeyError {
            switch passkeyError {
            case .prfNotSupported, .prfOutputMissing:
                return .prfUnsupported
            case .userCancelled:
                return .userCancelled
            case .timedOut:
                return .timedOut
            case .authorizationFailed, .randomGenerationFailed, .invalidBase64url:
                return .registerFailed
            case .presentationAnchorUnavailable:
                return .presentationUnavailable
            }
        }
        PasskeyDiagnostics.warn(
            "mapping unrecognized passkey error to userCancelled: \(err.localizedDescription)"
        )
        return .userCancelled
    }

    static func failureFromEnclaveError(_ err: SyncEnclaveError) -> PasskeyFlowFailure {
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

    private static func generateCek() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: SyncEnclaveKeyBundle.cekByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PasskeyError.randomGenerationFailed
        }
        return Data(bytes)
    }
}
