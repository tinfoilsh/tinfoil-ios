import CryptoKit
import Foundation
import Testing
import TinfoilPasskeyKit
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

    @Test func cachelessManagerRecoversDirectlyFromEvaluatedPRF() throws {
        let manager = try PasskeyKeyManager(
            profile: TinfoilPasskeyProfile.current,
            relyingPartyName: Constants.Passkey.rpName
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
            storage: FailingPasskeyStorage()
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

        #expect(PasskeyKeyFlow.failureFromPasskeyError(unsupported) == .prfUnsupported)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(cancelled) == .userCancelled)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(timeout) == .userCancelled)
        #expect(PasskeyKeyFlow.failureFromPasskeyError(invalid) == .userCancelled)
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
