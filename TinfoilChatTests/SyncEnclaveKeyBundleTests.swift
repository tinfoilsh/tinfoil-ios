//
//  SyncEnclaveKeyBundleTests.swift
//  TinfoilChatTests
//
//  The wire bundle is just AES-GCM(plaintext). The modern shape wraps the
//  raw 32-byte CEK directly; the pre-v2 webapp wrapped a
//  {primary: <base64>, alternatives: [...]} envelope. Unwrap must accept
//  both so a user whose passkey was first registered on the old web wire
//  can still unlock on iOS.
//

import CryptoKit
import Foundation
import Testing
@testable import TinfoilChat

@Suite("SyncEnclaveKeyBundle unwrap tolerance")
struct SyncEnclaveKeyBundleTests {

    private func makeKek() -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return SymmetricKey(data: Data(bytes))
    }

    private func makeIv() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }

    private func encryptPlaintext(_ plaintext: Data, with kek: SymmetricKey, iv: Data) throws -> (kekIvHex: String, wrappedKeyHex: String) {
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: kek, nonce: nonce)
        var ciphertextAndTag = Data(sealed.ciphertext)
        ciphertextAndTag.append(sealed.tag)
        return (
            kekIvHex: iv.map { String(format: "%02x", $0) }.joined(),
            wrappedKeyHex: ciphertextAndTag.map { String(format: "%02x", $0) }.joined()
        )
    }

    @Test func unwrapsRawCekBundle() throws {
        let kek = makeKek()
        let iv = makeIv()
        let cek = Data((0..<32).map { UInt8($0 + 1) })
        let bundle = try encryptPlaintext(cek, with: kek, iv: iv)

        let unwrapped = try SyncEnclaveKeyBundle.unwrapCek(
            kek: kek,
            kekIvHex: bundle.kekIvHex,
            wrappedKeyHex: bundle.wrappedKeyHex
        )
        #expect(unwrapped == cek)
    }

    @Test func unwrapsLegacyJsonEnvelopeBundle() throws {
        let kek = makeKek()
        let iv = makeIv()
        let cek = Data((0..<32).map { UInt8($0 + 100) })
        let envelope: [String: Any] = [
            "primary": cek.base64EncodedString(),
            "alternatives": ["legacy-1", "legacy-2"],
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let bundle = try encryptPlaintext(plaintext, with: kek, iv: iv)

        let unwrapped = try SyncEnclaveKeyBundle.unwrapCek(
            kek: kek,
            kekIvHex: bundle.kekIvHex,
            wrappedKeyHex: bundle.wrappedKeyHex
        )
        #expect(unwrapped == cek)
    }

    @Test func unwrapsLegacyEnvelopeWithKeyBase36Primary() throws {
        let kek = makeKek()
        let iv = makeIv()
        let cek = Data((0..<32).map { UInt8($0 + 7) })
        let altCek = Data((0..<32).map { UInt8($0 + 50) })
        let primaryKeyString = EncryptionService.shared.encodeKeyFromBytes(cek)
        let altKeyString = EncryptionService.shared.encodeKeyFromBytes(altCek)
        let envelope: [String: Any] = [
            "primary": primaryKeyString,
            "alternatives": [altKeyString, "garbage-entry"],
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let bundle = try encryptPlaintext(plaintext, with: kek, iv: iv)

        let unwrapped = try SyncEnclaveKeyBundle.unwrapCekDetailed(
            kek: kek,
            kekIvHex: bundle.kekIvHex,
            wrappedKeyHex: bundle.wrappedKeyHex
        )
        #expect(unwrapped.cek == cek)
        #expect(unwrapped.legacyAlternativeKeys == [altKeyString])
    }

    @Test func legacyEnvelopeAlternativesExcludePrimaryAndMalformedEntries() throws {
        let kek = makeKek()
        let iv = makeIv()
        let cek = Data((0..<32).map { UInt8($0 + 9) })
        let primaryKeyString = EncryptionService.shared.encodeKeyFromBytes(cek)
        let envelope: [String: Any] = [
            "primary": primaryKeyString,
            "alternatives": [primaryKeyString, "key_short", ""],
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let bundle = try encryptPlaintext(plaintext, with: kek, iv: iv)

        let unwrapped = try SyncEnclaveKeyBundle.unwrapCekDetailed(
            kek: kek,
            kekIvHex: bundle.kekIvHex,
            wrappedKeyHex: bundle.wrappedKeyHex
        )
        #expect(unwrapped.cek == cek)
        #expect(unwrapped.legacyAlternativeKeys.isEmpty)
    }

    @Test func throwsWhenBundleIsNeitherShape() throws {
        let kek = makeKek()
        let iv = makeIv()
        let bogus = Data("not-json-and-not-32-bytes".utf8)
        let bundle = try encryptPlaintext(bogus, with: kek, iv: iv)

        #expect(throws: SyncEnclaveKeyBundleError.self) {
            _ = try SyncEnclaveKeyBundle.unwrapCek(
                kek: kek,
                kekIvHex: bundle.kekIvHex,
                wrappedKeyHex: bundle.wrappedKeyHex
            )
        }
    }
}
