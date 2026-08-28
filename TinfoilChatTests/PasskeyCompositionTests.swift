import CryptoKit
import Foundation
import Testing
import TinfoilPasskeyKit
import UIKit
@testable import TinfoilChat

@MainActor
@Suite("Passkey generic API composition")
struct PasskeyCompositionTests {
    @Test func tinfoilProfilePreservesProductionBytes() {
        let profile = TinfoilPasskeyProfile.current

        #expect(profile.version == 1)
        #expect(profile.relyingPartyId == "tinfoil.sh")
        #expect(profile.prfSalt == Data("tinfoil-chat-key-encryption".utf8))
        #expect(profile.hkdfInfo == Data("tinfoil-chat-kek-v1".utf8))
    }

    @Test func wrappedKeyAdapterRoundTripsEnclaveFields() {
        let fields = TinfoilWrappedKeyAdapter.EnclaveFields(
            credentialId: "AQID",
            kekIvHex: "000102030405060708090a0b",
            wrappedKeyHex: String(repeating: "ab", count: 48)
        )
        let wrapped = TinfoilWrappedKeyAdapter.wrappedKey(fields)

        let roundTrip = TinfoilWrappedKeyAdapter.enclaveFields(wrapped)

        #expect(roundTrip == fields)
        #expect(wrapped.profile == TinfoilPasskeyProfile.current)
    }

    @Test func canonicalCodecMatchesFinalNestedProfileRecord() throws {
        let wrapped = TinfoilWrappedKeyAdapter.wrappedKey(
            TinfoilWrappedKeyAdapter.EnclaveFields(
                credentialId: "AQID",
                kekIvHex: "000102030405060708090a0b",
                wrappedKeyHex: String(repeating: "ab", count: 48)
            )
        )
        let expected = "{\"version\":1,\"profile\":{\"version\":1,\"relyingPartyId\":\"tinfoil.sh\",\"prfSalt\":\"dGluZm9pbC1jaGF0LWtleS1lbmNyeXB0aW9u\",\"hkdfInfo\":\"dGluZm9pbC1jaGF0LWtlay12MQ\"},\"credentialId\":\"AQID\",\"kekIvHex\":\"000102030405060708090a0b\",\"wrappedKeyHex\":\"\(String(repeating: "ab", count: 48))\"}"

        let encoded = try encodeWrappedKeyRecord(wrapped)

        #expect(encoded == Data(expected.utf8))
        #expect(try decodeWrappedKeyRecord(encoded) == wrapped)
    }

    @Test func currentOnlyCandidatesUseGenericWrappedKeys() {
        let candidates = TinfoilWrappedKeyAdapter.partition(
            [bundle(id: "AQ", wrappedByteCount: 48)],
            preferredCredentialId: nil
        )

        #expect(candidates.current.map(\.bundle.credentialId) == ["AQ"])
        #expect(candidates.legacy.isEmpty)
    }

    @Test func legacyOnlyCandidatesNeverBecomeGenericWrappedKeys() {
        let candidates = TinfoilWrappedKeyAdapter.partition(
            [bundle(id: "AQ", wrappedByteCount: 80)],
            preferredCredentialId: nil
        )

        #expect(candidates.current.isEmpty)
        #expect(candidates.legacy.map(\.credentialId) == ["AQ"])
    }

    @Test func mixedCandidatesPreservePreferredCredentialAndAllKinds() {
        let candidates = TinfoilWrappedKeyAdapter.partition(
            [
                bundle(id: "AQ", wrappedByteCount: 48),
                bundle(id: "Ag", wrappedByteCount: 80),
                bundle(id: "Aw", wrappedByteCount: 48),
            ],
            preferredCredentialId: "Ag"
        )

        #expect(candidates.credentialIds == ["Ag", "AQ", "Aw"])
        #expect(candidates.current.map(\.bundle.credentialId) == ["AQ", "Aw"])
        #expect(candidates.legacy.map(\.credentialId) == ["Ag"])
    }

    @Test func selectedLegacyCredentialRoutesToLegacyEnvelope() {
        let candidates = TinfoilWrappedKeyAdapter.partition(
            [
                bundle(id: "AQ", wrappedByteCount: 48),
                bundle(id: "Ag", wrappedByteCount: 80),
            ],
            preferredCredentialId: "Ag"
        )

        guard case .legacy(let selected) = candidates.selection(credentialId: "Ag") else {
            Issue.record("Expected legacy credential selection")
            return
        }
        #expect(selected.credentialId == "Ag")
    }

    @Test func immediateRecoveryMapsToFinalKitInteraction() {
        #expect(PasskeyService.interaction(immediatelyAvailable: true) == .immediatelyAvailable)
        #expect(PasskeyService.interaction(immediatelyAvailable: false) == .interactive)
    }

    @Test func recoveryUnionDeduplicatesCurrentAndLegacyInPreferredOrder() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "current", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 48),
            ],
            legacy: [legacyEntry(id: "legacy"), legacyEntry(id: "shared")],
            preferredCredentialId: "legacy"
        )

        #expect(candidates.credentialIds == ["legacy", "current", "shared"])
    }

    @Test func legacyCredentialWithoutLocalHintRemainsARecoveryCandidate() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [],
            legacy: [legacyEntry(id: "synced-legacy")],
            preferredCredentialId: nil
        )

        #expect(candidates.credentialIds == ["synced-legacy"])
    }

    @Test func selectedCurrentCredentialUsesCurrentUnwrapPath() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "shared", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 80),
            ],
            legacy: [legacyEntry(id: "shared")],
            preferredCredentialId: nil
        )
        var currentEnvelopeAttempted = false
        var externalLegacyAttempted = false

        #expect(candidates.credentialIds == ["shared"])
        let route: String? = candidates.resolveSelectedCredential(
            credentialId: "shared",
            current: { _ in "current" },
            currentEnvelope: { _ in
                currentEnvelopeAttempted = true
                return "current-envelope"
            },
            legacy: { _ in
                externalLegacyAttempted = true
                return "legacy"
            }
        )

        #expect(route == "current")
        #expect(!currentEnvelopeAttempted)
        #expect(!externalLegacyAttempted)
    }

    @Test func selectedLegacyCredentialUsesValidatedLegacyPath() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [bundle(id: "current", wrappedByteCount: 48)],
            legacy: [legacyEntry(id: "legacy")],
            preferredCredentialId: nil
        )

        let route: String? = candidates.resolveSelectedCredential(
            credentialId: "legacy",
            current: { _ in "current" },
            currentEnvelope: { _ in "current-envelope" },
            legacy: { _ in "legacy" }
        )

        #expect(route == "legacy")
    }

    @Test func sharedCredentialUsesCurrentLegacyEnvelopeBeforeExternalLegacy() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "shared", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 80),
            ],
            legacy: [legacyEntry(id: "shared")],
            preferredCredentialId: nil
        )
        var currentAttempts = 0
        var externalLegacyAttempted = false

        #expect(candidates.credentialIds == ["shared"])
        let route: String? = candidates.resolveSelectedCredential(
            credentialId: "shared",
            current: { _ in
                currentAttempts += 1
                return nil
            },
            currentEnvelope: { _ in "current-envelope" },
            legacy: { _ in
                externalLegacyAttempted = true
                return "legacy"
            }
        )

        #expect(currentAttempts == 1)
        #expect(route == "current-envelope")
        #expect(!externalLegacyAttempted)
    }

    @Test func sharedCredentialFallsBackAfterAllCurrentRepresentationsFail() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "shared", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 80),
            ],
            legacy: [legacyEntry(id: "shared")],
            preferredCredentialId: nil
        )
        var attempts: [String] = []

        #expect(candidates.credentialIds == ["shared"])
        let route: String? = candidates.resolveSelectedCredential(
            credentialId: "shared",
            current: { _ in
                attempts.append("current")
                return nil
            },
            currentEnvelope: { _ in
                attempts.append("current-envelope")
                return nil
            },
            legacy: { _ in
                attempts.append("legacy")
                return "legacy"
            }
        )

        #expect(attempts == ["current", "current-envelope", "legacy"])
        #expect(route == "legacy")
    }

    @Test func freshInteractiveUnionCanAddLegacyAfterSilentFailure() {
        let immediate = PasskeyRecoveryCandidates(
            bundles: [bundle(id: "current", wrappedByteCount: 48)],
            legacy: [],
            preferredCredentialId: nil
        )
        let interactive = PasskeyRecoveryCandidates(
            bundles: [bundle(id: "current", wrappedByteCount: 48)],
            legacy: [legacyEntry(id: "legacy")],
            preferredCredentialId: nil
        )

        #expect(immediate.credentialIds == ["current"])
        #expect(interactive.credentialIds == ["current", "legacy"])
        #expect(interactive.resolveSelectedCredential(
            credentialId: "legacy",
            current: { _ in false },
            currentEnvelope: { _ in false },
            legacy: { _ in true }
        ) == true)
    }

    @Test func recoveryCandidatesEvaluateWithoutCapabilityPreflight() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [],
            legacy: [legacyEntry(id: "legacy")],
            preferredCredentialId: nil
        )

        #expect(!candidates.credentialIds.isEmpty)
        #expect(PasskeyService.interaction(immediatelyAvailable: false) == .interactive)
    }

    @Test func presentationAnchorProviderUsesInjectedActiveWindow() throws {
        let window = UIWindow(frame: .zero)
        let provider = TinfoilPasskeyPresentationAnchorProvider { window }

        #expect(try provider.requirePresentationAnchor() === window)
        #expect(provider.presentationAnchor === window)
    }

    @Test func presentationAnchorProviderReportsMissingActiveWindow() {
        let provider = TinfoilPasskeyPresentationAnchorProvider { nil }

        do {
            _ = try provider.requirePresentationAnchor()
            Issue.record("Expected missing presentation anchor error")
        } catch PasskeyError.presentationAnchorUnavailable {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func legacyPresentationRetryPreservesLegacyContext() async {
        let entry = LegacyPasskeyCredentialEntry(
            id: "AQ",
            iv: "iv",
            encryptedKeys: "keys",
            createdAt: nil,
            version: nil,
            syncVersion: nil,
            bundleVersion: nil
        )
        let context = PasskeyManager.recoveryRetryContext(
            legacyEntries: [entry],
            enclaveKeyId: "legacy-key-id"
        )
        var recoveredCredentialId: String?
        var recoveredKeyId: String?

        let result = await PasskeyManager.retryLegacyRecovery(
            context: context,
            recover: { entries, enclaveKeyId in
                recoveredCredentialId = entries.first?.id
                recoveredKeyId = enclaveKeyId
                return .success(LegacyPasskeyRecovery(
                    cek: Data(repeating: 1, count: 32),
                    keyIdHex: "legacy-key-id",
                    credentialId: entries[0].id,
                    legacyAlternatives: [],
                    promotion: LegacyPasskeyPromotion(
                        expectedEnclaveKeyId: enclaveKeyId,
                        keyB64: Data(repeating: 1, count: 32).base64EncodedString(),
                        credentialId: entries[0].id,
                        kekIvHex: String(repeating: "0", count: 24),
                        encryptedKeysHex: String(repeating: "0", count: 96)
                    )
                ))
            }
        )

        #expect(recoveredCredentialId == "AQ")
        #expect(recoveredKeyId == "legacy-key-id")
        guard let result, case .success = result else {
            Issue.record("Expected active-window legacy retry to succeed")
            return
        }
    }

    @Test func enclavePresentationRetryDoesNotRouteToLegacyRecovery() async {
        let context = PasskeyManager.recoveryRetryContext(
            legacyEntries: nil,
            enclaveKeyId: "current-key-id"
        )
        var legacyRecoveryCalled = false

        let result = await PasskeyManager.retryLegacyRecovery(
            context: context,
            recover: { _, _ in
                legacyRecoveryCalled = true
                return .failure(.userCancelled)
            }
        )

        #expect(result == nil)
        #expect(!legacyRecoveryCalled)
    }

    @Test func successfulLegacyRetryDismissesAndResumesExactlyOnce() {
        var dismissCount = 0
        var resumeCount = 0

        let completed = PasskeyManager.finishRecoveryRetry(
            appliedResult: .success,
            isCurrentAccount: true,
            dismiss: { dismissCount += 1 },
            resume: { resumeCount += 1 }
        )
        let failed = PasskeyManager.finishRecoveryRetry(
            appliedResult: .recoveryFailed,
            isCurrentAccount: true,
            dismiss: { dismissCount += 1 },
            resume: { resumeCount += 1 }
        )
        let cancelled = PasskeyManager.finishRecoveryRetry(
            appliedResult: .success,
            isCurrentAccount: false,
            dismiss: { dismissCount += 1 },
            resume: { resumeCount += 1 }
        )

        #expect(completed)
        #expect(!failed)
        #expect(!cancelled)
        #expect(dismissCount == 1)
        #expect(resumeCount == 1)
    }

    @Test func manualRouteClearsLegacyRetryBeforeCurrentEnclaveRetry() async {
        let entry = LegacyPasskeyCredentialEntry(
            id: "AQ",
            iv: "iv",
            encryptedKeys: "keys",
            createdAt: nil,
            version: nil,
            syncVersion: nil,
            bundleVersion: nil
        )
        var pendingContext: PasskeyManager.RecoveryRetryContext? = .legacy(
            entries: [entry],
            enclaveKeyId: nil
        )

        PasskeyManager.clearRecoveryRetryContext(&pendingContext)
        #expect(pendingContext == nil)
        var staleLegacyRecoveryCalled = false
        let legacyResult = await PasskeyManager.retryLegacyRecovery(
            context: .enclave,
            recover: { _, _ in
                staleLegacyRecoveryCalled = true
                return .failure(.userCancelled)
            }
        )

        #expect(legacyResult == nil)
        #expect(!staleLegacyRecoveryCalled)
    }

    @Test func manualRecoverySuccessClearsPendingLegacyContext() {
        let entry = LegacyPasskeyCredentialEntry(
            id: "AQ",
            iv: "iv",
            encryptedKeys: "keys",
            createdAt: nil,
            version: nil,
            syncVersion: nil,
            bundleVersion: nil
        )
        var pendingContext: PasskeyManager.RecoveryRetryContext? = .legacy(
            entries: [entry],
            enclaveKeyId: "legacy-key-id"
        )

        PasskeyManager.clearRecoveryRetryContext(&pendingContext)

        #expect(pendingContext == nil)
    }

    @Test func staleLegacyRetryContextCannotReplayChangedCredential() {
        let stored = LegacyPasskeyCredentialEntry(
            id: "AQ",
            iv: "old-iv",
            encryptedKeys: "old-keys",
            createdAt: nil,
            version: nil,
            syncVersion: nil,
            bundleVersion: nil
        )
        let current = LegacyPasskeyCredentialEntry(
            id: "Ag",
            iv: "new-iv",
            encryptedKeys: "new-keys",
            createdAt: nil,
            version: nil,
            syncVersion: nil,
            bundleVersion: nil
        )

        let validated = PasskeyManager.validatedLegacyRetryContext(
            context: .legacy(entries: [stored], enclaveKeyId: "key-id"),
            currentEntries: [current],
            currentEnclaveKeyId: "key-id"
        )

        #expect(validated == nil)
    }

    @Test func legacyRecoveryRejectsRotatedEnclaveKey() {
        let expectedAccount = PasskeyManager.LegacyRecoveryAccountSnapshot(
            userId: "user-a",
            generation: 3
        )
        let currentKeyId = "rotated-key-id"
        let recoveredKeyId = "old-key-id"

        let canApply = PasskeyManager.canApplyLegacyRecovery(
            recoveredKeyId: recoveredKeyId,
            currentKeyId: currentKeyId,
            expectedAccount: expectedAccount,
            currentUserId: "user-a",
            currentGeneration: 3
        )
        #expect(!canApply)
    }

    @Test func currentRecoveryRejectsAccountOrKeyRotationDuringCeremony() {
        let expectedAccount = PasskeyManager.LegacyRecoveryAccountSnapshot(
            userId: "user-a",
            generation: 3
        )
        let rotatedState = currentKeyState(keyId: "rotated-key", credentialIds: ["AQ"])
        let currentState = currentKeyState(keyId: "current-key", credentialIds: ["AQ"])

        #expect(!PasskeyManager.canApplyCurrentRecovery(
            recoveredKeyId: "current-key",
            credentialId: "AQ",
            currentState: rotatedState,
            expectedAccount: expectedAccount,
            currentUserId: "user-a",
            currentGeneration: 3
        ))
        #expect(!PasskeyManager.canApplyCurrentRecovery(
            recoveredKeyId: "current-key",
            credentialId: "AQ",
            currentState: currentState,
            expectedAccount: expectedAccount,
            currentUserId: "user-b",
            currentGeneration: 4
        ))
    }

    @Test func accountSwitchWithNoEnclaveKeySkipsLegacyRegistration() {
        let promotion = LegacyPasskeyPromotion(
            expectedEnclaveKeyId: nil,
            keyB64: Data(repeating: 1, count: 32).base64EncodedString(),
            credentialId: "AQ",
            kekIvHex: String(repeating: "0", count: 24),
            encryptedKeysHex: String(repeating: "0", count: 96)
        )
        let recovery = LegacyPasskeyRecovery(
            cek: Data(repeating: 1, count: 32),
            keyIdHex: "recovered-key-id",
            credentialId: "AQ",
            legacyAlternatives: [],
            promotion: promotion
        )
        let plan = PasskeyManager.legacyPromotionPlan(
            recovery: recovery,
            currentKeyId: nil,
            isCurrentAccount: false
        )
        #expect(plan == nil)
    }

    @Test func promotionFailureCompletesRecoveryIntoNormalSetupPath() {
        let resolution = PasskeyManager.legacyPromotionResolution(
            promotionSucceeded: false,
            identityValid: true
        )
        var completionCount = 0
        var completion: (() -> Void)? = { completionCount += 1 }

        #expect(resolution.applyKey)
        #expect(!resolution.markPasskeyActive)
        #expect(resolution.makePasskeySetupAvailable)
        PasskeyManager.takeRecoveryCompletion(&completion)?()
        PasskeyManager.takeRecoveryCompletion(&completion)?()
        #expect(completionCount == 1)
        #expect(completion == nil)
    }

    @Test func restoreGuardRejectsStaleAccount() {
        let expected = PasskeyManager.LegacyRecoveryAccountSnapshot(
            userId: "user-a",
            generation: 4
        )

        #expect(!PasskeyManager.isExpectedLegacyRecoveryAccount(
            expected,
            currentUserId: "user-b",
            currentGeneration: 5
        ))
    }

    @Test func restoreGuardMatchesCurrentAccount() {
        let expected = PasskeyManager.LegacyRecoveryAccountSnapshot(
            userId: "user-a",
            generation: 4
        )

        #expect(PasskeyManager.isExpectedLegacyRecoveryAccount(
            expected,
            currentUserId: "user-a",
            currentGeneration: 4
        ))
    }

    @Test func validSameAccountPromotesRecoveredLegacyKey() async throws {
        let promotion = LegacyPasskeyPromotion(
            expectedEnclaveKeyId: nil,
            keyB64: Data(repeating: 2, count: 32).base64EncodedString(),
            credentialId: "AQ",
            kekIvHex: String(repeating: "1", count: 24),
            encryptedKeysHex: String(repeating: "1", count: 96)
        )
        let recovery = LegacyPasskeyRecovery(
            cek: Data(repeating: 2, count: 32),
            keyIdHex: "recovered-key-id",
            credentialId: "AQ",
            legacyAlternatives: [],
            promotion: promotion
        )
        let plan = try #require(PasskeyManager.legacyPromotionPlan(
            recovery: recovery,
            currentKeyId: nil,
            isCurrentAccount: true
        ))
        var registerCount = 0
        var addBundleCount = 0

        let promoted = await PasskeyManager.executeLegacyPromotion(
            plan,
            register: { _ in registerCount += 1 },
            addBundle: { _ in addBundleCount += 1 }
        )

        #expect(promoted)
        #expect(registerCount == 1)
        #expect(addBundleCount == 0)
    }

    @Test func cachelessManagerRecoversDirectlyFromEvaluatedPRF() throws {
        let manager = try PasskeyKeyManager(
            profile: TinfoilPasskeyProfile.current,
            relyingPartyName: Constants.Passkey.rpName,
            presentationAnchorProvider: FakePasskeyPresentationAnchorProvider()
        )
        let key = Data((0..<32).map(UInt8.init))
        let prfResult = PRFResult(output: Data(repeating: 7, count: 32))
        let wrapped = try manager.wrapKeyWithPRFResult(
            keyMaterial: key,
            credentialId: "AQ",
            prfResult: prfResult
        )

        #expect(try manager.recoverKeyFromCache(wrappedKeys: [wrapped]) == nil)
        #expect(try manager.unwrapKeyWithPRFResult(
            wrappedKey: wrapped,
            prfResult: prfResult
        ) == key)
    }

    @Test func failingStorageDoesNotBlockDirectPRFRecovery() throws {
        let manager = try PasskeyKeyManager(
            profile: TinfoilPasskeyProfile.current,
            relyingPartyName: Constants.Passkey.rpName,
            storage: FailingPasskeyStorage(),
            presentationAnchorProvider: FakePasskeyPresentationAnchorProvider()
        )
        let key = Data((0..<32).map { UInt8($0 + 10) })
        let prfResult = PRFResult(output: Data(repeating: 9, count: 32))
        let wrapped = try manager.wrapKeyWithPRFResult(
            keyMaterial: key,
            credentialId: "Ag",
            prfResult: prfResult
        )

        #expect(try manager.recoverKeyFromCache(wrappedKeys: [wrapped]) == nil)
        #expect(try manager.unwrapKeyWithPRFResult(
            wrappedKey: wrapped,
            prfResult: prfResult
        ) == key)
    }

    @Test func validatedPRFSnapshotSurvivesCacheCredentialSwap() throws {
        var cached = CachedPRFResult(
            profile: TinfoilPasskeyProfile.current,
            credentialId: "AQ",
            prfOutput: Data(repeating: 4, count: 32)
        )
        let snapshot = try #require(LegacyBlobMigration.validatedPasskeySnapshot(
            cached: cached,
            credentialIds: ["AQ"]
        ))
        cached = CachedPRFResult(
            profile: TinfoilPasskeyProfile.current,
            credentialId: "Ag",
            prfOutput: Data(repeating: 8, count: 32)
        )
        let manager = try PasskeyKeyManager(
            profile: TinfoilPasskeyProfile.current,
            relyingPartyName: Constants.Passkey.rpName,
            presentationAnchorProvider: FakePasskeyPresentationAnchorProvider()
        )
        let key = Data((0..<32).map(UInt8.init))

        let wrapped = try manager.wrapKeyWithPRFResult(
            keyMaterial: key,
            credentialId: snapshot.credentialId,
            prfResult: snapshot.prfResult
        )

        #expect(wrapped.credentialId == "AQ")
        #expect(try manager.unwrapKeyWithPRFResult(
            wrappedKey: wrapped,
            prfResult: snapshot.prfResult
        ) == key)
        #expect(throws: PasskeyKeyError.self) {
            try manager.unwrapKeyWithPRFResult(
                wrappedKey: wrapped,
                prfResult: PRFResult(output: cached.prfOutput)
            )
        }
    }

    @Test func oldPRFCacheRecordReconstructsTinfoilProfile() throws {
        let oldRecord = try JSONSerialization.data(withJSONObject: [
            "credentialId": "AQID",
            "prfOutput": Data(repeating: 7, count: 32).base64EncodedString(),
            "isPlatformAuthenticator": true,
        ], options: [.sortedKeys])

        let decoded = try TinfoilPasskeyKeyStorage.decodeCachedRecord(oldRecord)

        #expect(decoded.credentialId == "AQID")
        #expect(decoded.prfOutput == Data(repeating: 7, count: 32))
        #expect(decoded.profile == TinfoilPasskeyProfile.current)
    }

    @Test func priorGenericCacheRecordDropsPresentationName() throws {
        let oldRecord = try JSONSerialization.data(withJSONObject: [
            "profile": [
                "version": 1,
                "relyingPartyId": "tinfoil.sh",
                "relyingPartyName": "Tinfoil Chat",
                "prfSalt": TinfoilPasskeyProfile.prfSalt.base64EncodedString(),
                "hkdfInfo": TinfoilPasskeyProfile.hkdfInfo.base64EncodedString(),
            ],
            "credentialId": "AQID",
            "prfOutput": Data(repeating: 9, count: 32).base64EncodedString(),
        ], options: [.sortedKeys])

        let decoded = try TinfoilPasskeyKeyStorage.decodeCachedRecord(oldRecord)

        #expect(decoded.profile == TinfoilPasskeyProfile.current)
        #expect(decoded.credentialId == "AQID")
        #expect(decoded.prfOutput == Data(repeating: 9, count: 32))
    }

    @Test func bundleInventoryVerificationUsesLocalAndRemoteKeyIds() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["AQ"])

        let matching = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "current-key"
        )
        let mismatching = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "rotated-key"
        )
        let unverified = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: nil
        )

        #expect(matching.verification == .match)
        #expect(mismatching.verification == .mismatch)
        #expect(unverified.verification == .unverified)
    }

    @Test func unverifiedLegacyLookupDisablesBundleRemovalVerification() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["AQ"])
        let inventory = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "current-key",
            legacyLookup: .unverified
        )
        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            localCredentialId: "AQ",
            legacyStatus: inventory.legacyStatus
        )

        #expect(inventory.verification == .unverified)
        #expect(inventory.legacyStatus == .unverified)
        #expect(availability.active)
        #expect(!availability.setupAvailable)
    }

    @Test func failedInventoryRefreshPreservesBundlesButDisablesRemoval() {
        let inventory = PasskeyManager.passkeyBundleInventory(
            state: currentKeyState(keyId: "current-key", credentialIds: ["AQ", "Ag"]),
            localKeyId: "current-key"
        )

        let failedRefresh = inventory.preservingBundlesAsUnverified()

        #expect(Set(failedRefresh.bundles.map(\.credentialId)) == Set(["AQ", "Ag"]))
        #expect(failedRefresh.verification == .unverified)
    }

    @Test func passkeyRemovalRejectsRotationBetweenInventoryAndMutation() {
        let inventoryState = currentKeyState(keyId: "old-key", credentialIds: ["AQ"])
        let mutationState = currentKeyState(keyId: "rotated-key", credentialIds: ["AQ"])

        #expect(PasskeyManager.passkeyBundleInventory(
            state: inventoryState,
            localKeyId: "old-key"
        ).verification == .match)
        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: mutationState,
            localKeyId: "old-key"
        ) == .reject(.keyMismatch))
    }

    @Test func mismatchedKeyCannotReportPasskeyActive() {
        let state = currentKeyState(keyId: "rotated-key", credentialIds: ["AQ"])

        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "old-key"
        )
        let emptyMismatch = PasskeyManager.passkeyBundleAvailability(
            state: currentKeyState(keyId: "rotated-key", credentialIds: []),
            localKeyId: "old-key"
        )

        #expect(!availability.active)
        #expect(!availability.setupAvailable)
        #expect(!availability.addDeviceAvailable)
        #expect(!availability.keyMatches)
        #expect(!emptyMismatch.setupAvailable)
    }

    @Test func passkeyRemovalAllowsFinalBundleWithoutBackupGate() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["AQ"])

        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: state,
            localKeyId: "current-key"
        ) == .remove)
    }

    @Test func finalBundleRemovalStaysInactiveWhenRefreshFails() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["AQ"])
        let updatedState = PasskeyManager.removingPasskeyBundle(
            credentialId: "AQ",
            from: state
        )

        let deterministicAvailability = PasskeyManager.passkeyBundleAvailability(
            state: updatedState,
            localKeyId: "current-key"
        )

        #expect(updatedState.bundles.isEmpty)
        #expect(!deterministicAvailability.active)
        #expect(deterministicAvailability.setupAvailable)
        #expect(!deterministicAvailability.addDeviceAvailable)
    }

    @Test func finalEnclaveBundleRemovalKeepsLegacyRecoveryActive() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["AQ"])
        let updatedState = PasskeyManager.removingPasskeyBundle(
            credentialId: "AQ",
            from: state
        )
        let legacyLookup = LegacyPasskeyCredentialLookup.available([legacyEntry(id: "AQ")])
        let inventory = PasskeyManager.passkeyBundleInventory(
            state: updatedState,
            localKeyId: "current-key",
            legacyLookup: legacyLookup
        )
        let availability = PasskeyManager.passkeyBundleAvailability(
            state: updatedState,
            localKeyId: "current-key",
            localCredentialId: "AQ",
            legacyStatus: inventory.legacyStatus,
            legacyCredentialIds: Set(inventory.legacyCredentials.map(\.id))
        )

        #expect(inventory.bundles.isEmpty)
        #expect(inventory.legacyCredentials.map(\.id) == ["AQ"])
        #expect(inventory.legacyStatus == .present)
        #expect(availability.active)
        #expect(!availability.setupAvailable)
    }

    @Test func legacyCredentialWithoutLocalHintOffersDeviceSetup() {
        let state = currentKeyState(keyId: "current-key", credentialIds: [])
        let inventory = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "current-key",
            legacyLookup: .available([legacyEntry(id: "other")])
        )

        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            legacyStatus: inventory.legacyStatus
        )

        #expect(inventory.legacyCredentials.map(\.id) == ["other"])
        #expect(!availability.active)
        #expect(availability.addDeviceAvailable)
    }

    @Test func legacyLookupFailureLeavesRecoveryUnverified() {
        let state = currentKeyState(keyId: "current-key", credentialIds: [])
        let previous = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "current-key",
            legacyLookup: .available([legacyEntry(id: "legacy")])
        )
        let refreshed = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "current-key",
            legacyLookup: .unverified
        )
        let inventory = refreshed.preservingLegacyCredentials(from: previous)
        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            legacyStatus: inventory.legacyStatus
        )

        #expect(inventory.verification == .unverified)
        #expect(inventory.legacyStatus == .unverified)
        #expect(inventory.legacyCredentials.map(\.id) == ["legacy"])
        #expect(!availability.active)
        #expect(!availability.setupAvailable)
    }

    @Test func otherDeviceCurrentBundleOffersLocalPasskeySetup() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["other-device"])

        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            localCredentialId: "this-device"
        )

        #expect(!availability.active)
        #expect(!availability.setupAvailable)
        #expect(availability.addDeviceAvailable)
    }

    @Test func matchingLegacyCredentialPreventsDuplicateDeviceSetup() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["other-device"])

        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            localCredentialId: "this-device",
            legacyStatus: .present,
            legacyCredentialIds: ["this-device"]
        )

        #expect(availability.active)
        #expect(!availability.addDeviceAvailable)
    }

    @Test func externalLegacyKeyMismatchOutranksDecryptFailure() {
        let selected = PasskeyKeyFlow.preferredExternalLegacyFailure(
            .failure(.bundleDecryptFailed, message: "decrypt failed"),
            over: .failure(.keyIdMismatch, message: "wrong key")
        )

        guard let selected, case .failure(let failure, let message) = selected else {
            Issue.record("Expected a preserved external legacy failure")
            return
        }
        #expect(failure == .keyIdMismatch)
        #expect(message == "wrong key")
    }

    @Test func externalLegacyKeyMismatchIsNotReplacedByDecryptFailure() {
        let selected = PasskeyKeyFlow.preferredExternalLegacyFailure(
            .failure(.keyIdMismatch, message: "wrong key"),
            over: .failure(.bundleDecryptFailed, message: "decrypt failed")
        )

        guard let selected, case .failure(let failure, let message) = selected else {
            Issue.record("Expected the key mismatch to remain available")
            return
        }
        #expect(failure == .keyIdMismatch)
        #expect(message == "wrong key")
    }

    @Test func finalEnclaveBundleWithoutLegacyRecoveryNeedsSetup() {
        let state = PasskeyManager.removingPasskeyBundle(
            credentialId: "AQ",
            from: currentKeyState(keyId: "current-key", credentialIds: ["AQ"])
        )
        let inventory = PasskeyManager.passkeyBundleInventory(
            state: state,
            localKeyId: "current-key",
            legacyLookup: .available([])
        )
        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            legacyStatus: inventory.legacyStatus
        )

        #expect(inventory.legacyStatus == .absent)
        #expect(!availability.active)
        #expect(availability.setupAvailable)
    }

    @Test func missingPasskeyBundleRemovalIsIdempotent() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["Ag"])

        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: state,
            localKeyId: "current-key"
        ) == .alreadyMissing)
        #expect(PasskeyManager.passkeyBundleRemovalError(from: SyncEnclaveError(
            message: "missing",
            status: 404,
            code: WireCodes.notFound
        )) == .missing)
    }

    @Test func bundleMissingAfterRotationRemainsIdempotent() {
        let rotatedState = currentKeyState(keyId: "rotated-key", credentialIds: ["Ag"])

        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: rotatedState,
            localKeyId: "old-key"
        ) == .alreadyMissing)
    }

    @Test func absentFinalBundleProducesInactiveSetupState() {
        let state = currentKeyState(keyId: "current-key", credentialIds: [])

        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: state,
            localKeyId: "current-key"
        ) == .alreadyMissing)

        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key"
        )
        #expect(!availability.active)
        #expect(availability.setupAvailable)
    }

    @Test func absentBundlePreservesActiveRemainingLocalBundle() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["Ag"])

        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: state,
            localKeyId: "current-key"
        ) == .alreadyMissing)

        let availability = PasskeyManager.passkeyBundleAvailability(
            state: state,
            localKeyId: "current-key",
            localCredentialId: "Ag"
        )
        #expect(availability.active)
        #expect(!availability.setupAvailable)
    }

    @Test func passkeyRemovalErrorsRemainTyped() {
        #expect(PasskeyManager.passkeyBundleRemovalError(from: SyncEnclaveError(
            message: "sign in",
            status: 401,
            code: WireCodes.authActionRequired
        )) == .authentication)
        #expect(PasskeyManager.passkeyBundleRemovalError(from: SyncEnclaveError(
            message: "rotated",
            status: 409,
            code: WireCodes.staleKey
        )) == .keyMismatch)
        #expect(PasskeyManager.passkeyBundleRemovalError(from: SyncEnclaveError(
            message: "unavailable",
            status: 503
        )) == .server)
    }

    @Test func keyIdentifierMatchesTinfoilVector() throws {
        let cek = Data((0..<32).map(UInt8.init))

        let keyId = try SyncEnclaveKeyBundle.deriveKeyIdHex(cek: cek)

        #expect(keyId == "960e28ca37b723e7abc19995dbef143f")
    }

    @Test func stableKitErrorsMapToExistingFlowCategories() {
        let unsupported = PasskeyService.mapError(PasskeyKeyError.unsupported())
        let cancelled = PasskeyService.mapError(PasskeyKeyError.cancelled())
        let timeout = PasskeyService.mapError(PasskeyKeyError.timeout())
        let invalid = PasskeyService.mapError(PasskeyKeyError.invalidInput())
        let missingAnchor = PasskeyError.presentationAnchorUnavailable

        #expect(PasskeyKeyFlow.failureFromPasskeyError(unsupported) == .prfUnsupported)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(cancelled) == .userCancelled)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(timeout) == .userCancelled)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(invalid) == .userCancelled)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(missingAnchor) == .presentationUnavailable)
    }

    @Test func sharedHexParserRejectsMalformedInputAtBothBoundaries() {
        #expect(throws: SyncEnclaveError.self) { try hexToData("") }
        #expect(throws: SyncEnclaveError.self) { try hexToData("0") }
        #expect(throws: SyncEnclaveError.self) { try hexToData("zz") }
        #expect(throws: SyncEnclaveKeyBundleError.self) {
            try SyncEnclaveKeyBundle.unwrapLegacyJsonEnvelope(
                prfOutput: Data(repeating: 1, count: 32),
                kekIvHex: "zz",
                wrappedKeyHex: String(repeating: "00", count: 16)
            )
        }
    }

    @Test func accountGenerationRejectsPasskeyCompletionFromPriorAccount() {
        var fence = AccountOperationFence()
        let passkeyOperation = fence.begin(userId: "user-a")
        _ = fence.begin(userId: "user-b")

        #expect(!fence.isCurrent(passkeyOperation, currentUserId: "user-b"))
    }

    private func bundle(id: String, wrappedByteCount: Int) -> EnclaveKeyCurrentBundle {
        EnclaveKeyCurrentBundle(
            credentialId: id,
            kekIv: String(repeating: "0", count: 24),
            encryptedKeys: String(repeating: "0", count: wrappedByteCount * 2),
            bundleVersion: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func currentKeyState(
        keyId: String?,
        credentialIds: [String]
    ) -> EnclaveKeyCurrentResponse {
        EnclaveKeyCurrentResponse(
            keyId: keyId,
            etag: nil,
            bundles: Dictionary(uniqueKeysWithValues: credentialIds.map { id in
                (id, bundle(id: id, wrappedByteCount: 48))
            }),
            createdVia: nil,
            createdAt: nil,
            hasData: false
        )
    }

    private func legacyEntry(id: String) -> LegacyPasskeyCredentialEntry {
        LegacyPasskeyCredentialEntry(
            id: id,
            iv: "iv",
            encryptedKeys: "keys",
            createdAt: nil,
            version: nil,
            syncVersion: nil,
            bundleVersion: nil
        )
    }
}

@Suite("Legacy passkey envelope fallback")
struct LegacyPasskeyEnvelopeTests {
    @Test func unwrapsLegacyJSONAndRetainsOnlyValidAlternatives() throws {
        let prfOutput = Data(repeating: 3, count: 32)
        let cek = Data((0..<32).map { UInt8($0 + 1) })
        let alternative = Data((0..<32).map { UInt8($0 + 40) })
        let primaryString = EncryptionService.shared.encodeKeyFromBytes(cek)
        let alternativeString = EncryptionService.shared.encodeKeyFromBytes(alternative)
        let plaintext = try JSONSerialization.data(withJSONObject: [
            "primary": primaryString,
            "alternatives": [primaryString, alternativeString, "invalid"],
        ], options: [.sortedKeys])
        let iv = Data((0..<12).map(UInt8.init))
        let kek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: prfOutput),
            salt: Data(),
            info: TinfoilPasskeyProfile.hkdfInfo,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: kek, nonce: AES.GCM.Nonce(data: iv))
        var encrypted = Data(sealed.ciphertext)
        encrypted.append(sealed.tag)

        let recovered = try SyncEnclaveKeyBundle.unwrapLegacyJsonEnvelope(
            prfOutput: prfOutput,
            kekIvHex: iv.map { String(format: "%02x", $0) }.joined(),
            wrappedKeyHex: encrypted.map { String(format: "%02x", $0) }.joined()
        )

        #expect(recovered.cek == cek)
        #expect(recovered.legacyAlternativeKeys == [alternativeString])
    }
}

@MainActor
private final class FailingPasskeyStorage: PasskeyKeyStorage {
    struct Failure: Error {}

    func loadCachedPRFResult() throws -> CachedPRFResult? { throw Failure() }
    func saveCachedPRFResult(_ result: CachedPRFResult) throws { throw Failure() }
    func loadLocalCredentialId() throws -> String? { throw Failure() }
    func saveLocalCredentialId(_ credentialId: String) throws { throw Failure() }
    func clear() throws { throw Failure() }
}

@MainActor
private final class FakePasskeyPresentationAnchorProvider: PasskeyPresentationAnchorProviding {
    let presentationAnchor = UIWindow(frame: .zero)
}
