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
        #expect(profile.relyingPartyName == "Tinfoil Chat")
        #expect(profile.prfSalt == Data("tinfoil-chat-key-encryption".utf8))
        #expect(profile.hkdfInfo == Data("tinfoil-chat-kek-v1".utf8))
    }

    @Test func wrappedKeyAdapterPreservesEnclaveWireFields() {
        let wrapped = TinfoilWrappedKeyAdapter.wrappedKey(
            credentialId: "AQID",
            kekIvHex: "000102030405060708090a0b",
            wrappedKeyHex: String(repeating: "ab", count: 48)
        )

        let body = TinfoilWrappedKeyAdapter.bundleBody(wrapped)

        #expect(body.credentialId == "AQID")
        #expect(body.kekIvHex == "000102030405060708090a0b")
        #expect(body.wrappedKeyHex == String(repeating: "ab", count: 48))
        #expect(wrapped.profile == TinfoilPasskeyProfile.current)
    }

    @Test func preferredCredentialIsPresentedFirstWithoutDroppingBundles() {
        let first = TinfoilWrappedKeyAdapter.wrappedKey(
            credentialId: "AQ",
            kekIvHex: String(repeating: "0", count: 24),
            wrappedKeyHex: String(repeating: "0", count: 96)
        )
        let preferred = TinfoilWrappedKeyAdapter.wrappedKey(
            credentialId: "Ag",
            kekIvHex: String(repeating: "1", count: 24),
            wrappedKeyHex: String(repeating: "1", count: 96)
        )

        let ordered = TinfoilWrappedKeyAdapter.ordered(
            [first, preferred],
            preferredCredentialId: preferred.credentialId
        )

        #expect(ordered.map(\.credentialId) == ["Ag", "AQ"])
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
