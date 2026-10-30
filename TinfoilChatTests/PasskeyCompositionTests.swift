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

    @Test func selectedCurrentCredentialUsesCurrentUnwrapPath() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "shared", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 80),
            ],
            preferredCredentialId: nil
        )
        var currentEnvelopeAttempted = false

        #expect(candidates.credentialIds == ["shared"])
        let route: String? = candidates.resolveSelectedCredential(
            credentialId: "shared",
            current: { _ in "current" },
            currentEnvelope: { _ in
                currentEnvelopeAttempted = true
                return "current-envelope"
            }
        )

        #expect(route == "current")
        #expect(!currentEnvelopeAttempted)
    }

    @Test func sharedCredentialFallsBackToItsLegacyEnvelope() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "shared", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 80),
            ],
            preferredCredentialId: nil
        )
        var currentAttempts = 0

        #expect(candidates.credentialIds == ["shared"])
        let route: String? = candidates.resolveSelectedCredential(
            credentialId: "shared",
            current: { _ in
                currentAttempts += 1
                return nil
            },
            currentEnvelope: { _ in "current-envelope" }
        )

        #expect(currentAttempts == 1)
        #expect(route == "current-envelope")
    }

    @Test func sharedCredentialResolvesNothingAfterAllRepresentationsFail() {
        let candidates = PasskeyRecoveryCandidates(
            bundles: [
                bundle(id: "shared", wrappedByteCount: 48),
                bundle(id: "shared", wrappedByteCount: 80),
            ],
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
            }
        )

        #expect(attempts == ["current", "current-envelope"])
        #expect(route == nil)
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

    @Test func successfulRecoveryRetryDismissesAndResumesExactlyOnce() {
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

    @Test func currentRecoveryRejectsAccountOrKeyRotationDuringCeremony() {
        let expectedAccount = PasskeyManager.RecoveryAccountSnapshot(
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

    @Test func recoveryCompletionRunsExactlyOnce() {
        var completionCount = 0
        var completion: (() -> Void)? = { completionCount += 1 }

        PasskeyManager.takeRecoveryCompletion(&completion)?()
        PasskeyManager.takeRecoveryCompletion(&completion)?()
        #expect(completionCount == 1)
        #expect(completion == nil)
    }

    @Test func recoveryAccountGuardRejectsStaleAccount() {
        let expected = PasskeyManager.RecoveryAccountSnapshot(
            userId: "user-a",
            generation: 4
        )

        #expect(!PasskeyManager.isExpectedRecoveryAccount(
            expected,
            currentUserId: "user-b",
            currentGeneration: 5
        ))
    }

    @Test func recoveryAccountGuardMatchesCurrentAccount() {
        let expected = PasskeyManager.RecoveryAccountSnapshot(
            userId: "user-a",
            generation: 4
        )

        #expect(PasskeyManager.isExpectedRecoveryAccount(
            expected,
            currentUserId: "user-a",
            currentGeneration: 4
        ))
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

    @Test func missingPasskeyBundleRemovalIsIdempotent() {
        let state = currentKeyState(keyId: "current-key", credentialIds: ["Ag"])

        #expect(PasskeyManager.passkeyBundleRemovalDecision(
            credentialId: "AQ",
            state: state,
            localKeyId: "current-key"
        ) == .alreadyMissing)
        #expect(PasskeyManager.passkeyBundleRemovalError(from: HarnessError(
            code: HarnessErrorCode.threadNotFound, message: "missing", action: .stop, status: 404
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
        #expect(PasskeyManager.passkeyBundleRemovalError(from: HarnessError.unauthenticated) == .authentication)
        #expect(PasskeyManager.passkeyBundleRemovalError(from: HarnessError(
            code: HarnessErrorCode.keyMismatch, message: "rotated", action: .unlock, status: 409
        )) == .keyMismatch)
        #expect(PasskeyManager.passkeyBundleRemovalError(from: HarnessError(
            code: HarnessErrorCode.upstreamRefused, message: "unavailable", action: .retry, status: 503
        )) == .server)
    }

    @Test func keyIdentifierMatchesTinfoilVector() throws {
        let cek = Data((0..<32).map(UInt8.init))

        let keyId = try ContentKeyBundle.deriveKeyIdHex(cek: cek)

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
        #expect(PasskeyKeyFlow.failureFromPasskeyError(timeout) == .timedOut)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(invalid) == .registerFailed)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(missingAnchor) == .presentationUnavailable)
    }

    @Test func passkeySetupFailuresProvideActionableMessages() {
        let unsupported = PasskeySetupFailurePresentation(.prfUnsupported)
        let timeout = PasskeySetupFailurePresentation(.timedOut)

        #expect(unsupported.title == "Passkey Provider Not Supported")
        #expect(unsupported.message.contains("another passkey provider"))
        #expect(timeout.title == "Passkey Setup Timed Out")
        #expect(timeout.message.contains("try again"))
    }

    @Test func passkeySetupPreservesRegistryFailureCategories() {
        let offline = HarnessError(code: HarnessErrorCode.connection, message: "offline", action: .retry)
        let refused = HarnessError(code: HarnessErrorCode.upstreamRefused, message: "busy", action: .retry, status: 503)
        let taken = HarnessError(code: HarnessErrorCode.keyMismatch, message: "another key", action: .unlock, status: 409)

        #expect(PasskeyKeyFlow.failureFromRegistryError(offline) == .enclaveUnavailable)
        #expect(PasskeyKeyFlow.failureFromRegistryError(HarnessError(HarnessErrorBody.unverified)) == .enclaveUnavailable)
        #expect(PasskeyKeyFlow.failureFromRegistryError(refused) == .enclaveUnavailable)
        #expect(PasskeyKeyFlow.failureFromRegistryError(taken) == .remoteKeyExists)
        #expect(PasskeyKeyFlow.failureFromRegistryError(HarnessError.unauthenticated) == .registerFailed)
    }

    @Test func malformedHexIsRefusedAtBothBoundaries() {
        #expect(Data(lowercaseHex: "0") == nil)
        #expect(Data(lowercaseHex: "zz") == nil)
        #expect(throws: ContentKeyBundleError.self) {
            try ContentKeyBundle.unwrapLegacyJsonEnvelope(
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

    private func bundle(id: String, wrappedByteCount: Int) -> KeyState.Bundle {
        KeyState.Bundle(
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
    ) -> KeyState {
        KeyState(
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
}

@Suite("Legacy passkey envelope fallback")
struct LegacyPasskeyEnvelopeTests {
    @Test(arguments: ["%02x", "%02X"])
    func unwrapsLegacyJSONAndRetainsOnlyValidAlternatives(hexFormat: String) throws {
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

        let recovered = try ContentKeyBundle.unwrapLegacyJsonEnvelope(
            prfOutput: prfOutput,
            kekIvHex: iv.map { String(format: hexFormat, $0) }.joined(),
            wrappedKeyHex: encrypted.map { String(format: hexFormat, $0) }.joined()
        )

        #expect(recovered.cek == cek)
        #expect(recovered.legacyAlternativeKeys == [alternativeString])
    }
}

@MainActor
@Suite("Generic key envelope")
struct GenericKeyEnvelopeTests {
    private let credentialId = "AQID"
    private let prfResult = PRFResult(output: Data(repeating: 5, count: 32))
    private let primaryKey = Data((0..<32).map { UInt8($0 + 1) })
    private let alternativeKeys = [Data((0..<32).map { UInt8($0 + 60) }), Data((0..<32).map { UInt8($0 + 120) })]

    @Test func readsTheEnvelopeTheWebAppWrites() throws {
        let bundle = try envelopeBundle(primary: wrap(primaryKey), alternatives: alternativeKeys.map { try wrap($0) })

        let candidates = TinfoilWrappedKeyAdapter.partition([bundle], preferredCredentialId: nil)

        #expect(candidates.legacy.isEmpty)
        #expect(candidates.credentialIds == [credentialId])
        let current = try #require(candidates.current.first)
        #expect(current.alternatives.count == alternativeKeys.count)
        let unwrapped = try PasskeyKeyFlow.unwrapCurrent(current, prfResult: prfResult)
        #expect(unwrapped.cek == primaryKey)
        #expect(unwrapped.legacyAlternativeKeys == alternativeKeys.map(EncryptionService.shared.encodeKeyFromBytes))
    }

    @Test func refusesAnEnvelopeWrappedForAnotherPasskey() throws {
        let bundle = try envelopeBundle(primary: wrap(primaryKey), alternatives: [wrap(alternativeKeys[0], credentialId: "Ag")])

        let candidates = TinfoilWrappedKeyAdapter.partition([bundle], preferredCredentialId: nil)

        #expect(candidates.current.isEmpty)
        #expect(candidates.legacy.isEmpty)
        #expect(candidates.credentialIds.isEmpty)
    }

    @Test func refusesAnEnvelopeWithUnexpectedMembers() throws {
        let bundle = try envelopeBundle(primary: wrap(primaryKey), alternatives: [], extraMember: ",\"note\":\"x\"")

        let candidates = TinfoilWrappedKeyAdapter.partition([bundle], preferredCredentialId: nil)

        #expect(candidates.current.isEmpty)
        #expect(candidates.legacy.isEmpty)
    }

    @Test func refusesAnEnvelopeThatNamesTheKeyTwice() throws {
        let bundle = try envelopeBundle(primary: wrap(primaryKey), alternatives: [wrap(primaryKey)])
        let current = try #require(TinfoilWrappedKeyAdapter.partition([bundle], preferredCredentialId: nil).current.first)

        #expect(throws: ContentKeyBundleError.self) {
            try PasskeyKeyFlow.unwrapCurrent(current, prfResult: prfResult)
        }
    }

    private func wrap(_ key: Data, credentialId: String? = nil) throws -> WrappedKey {
        try PasskeyKeyManager(
            profile: TinfoilPasskeyProfile.current,
            relyingPartyName: Constants.Passkey.rpName,
            presentationAnchorProvider: FakePasskeyPresentationAnchorProvider()
        ).wrapKeyWithPRFResult(keyMaterial: key, credentialId: credentialId ?? self.credentialId, prfResult: prfResult)
    }

    /// A bundle as web app v1.0.2 stores it: the primary key's IV, and the
    /// envelope's JSON text, hex, as the wrapped keys.
    private func envelopeBundle(primary: WrappedKey, alternatives: [WrappedKey], extraMember: String = "") throws -> KeyState.Bundle {
        let encoder = JSONEncoder()
        func record(_ wrappedKey: WrappedKey) throws -> String {
            String(decoding: try encoder.encode(String(decoding: try encodeWrappedKeyRecord(wrappedKey), as: UTF8.self)), as: UTF8.self)
        }
        let envelope = "{\"version\":1,\"authorizationMode\":\"validated\",\"primary\":\(try record(primary)),"
            + "\"alternatives\":[\(try alternatives.map(record).joined(separator: ","))]\(extraMember)}"
        return KeyState.Bundle(
            credentialId: credentialId,
            kekIv: primary.kekIvHex,
            encryptedKeys: Data(envelope.utf8).hexEncodedString(),
            bundleVersion: 1,
            createdAt: nil,
            updatedAt: nil
        )
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
