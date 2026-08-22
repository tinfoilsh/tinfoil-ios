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
                return .success(
                    cek: Data(repeating: 1, count: 32),
                    keyIdHex: "legacy-key-id",
                    credentialId: entries[0].id,
                    createdVia: nil
                )
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
        let currentContext = pendingContext ?? .enclave
        var staleLegacyRecoveryCalled = false
        let legacyResult = await PasskeyManager.retryLegacyRecovery(
            context: currentContext,
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

    @Test func delayedLegacyRecoveryRejectsRotatedEnclaveKey() async {
        let expectedAccount = PasskeyManager.LegacyRecoveryAccountSnapshot(
            userId: "user-a",
            generation: 3
        )
        let delayedRecovery = Task { @MainActor in
            await Task.yield()
            return "old-key-id"
        }
        let currentKeyId = "rotated-key-id"
        let recoveredKeyId = await delayedRecovery.value
        var appliedRecoveredKey = false

        let canApply = PasskeyManager.canApplyLegacyRecovery(
            recoveredKeyId: recoveredKeyId,
            currentKeyId: currentKeyId,
            expectedAccount: expectedAccount,
            currentUserId: "user-a",
            currentGeneration: 3
        )
        if canApply { appliedRecoveredKey = true }

        #expect(!canApply)
        #expect(!appliedRecoveredKey)
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
