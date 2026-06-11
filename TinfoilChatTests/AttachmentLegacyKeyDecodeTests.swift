//
//  AttachmentLegacyKeyDecodeTests.swift
//  TinfoilChatTests
//
//  The oldest attachment rows on disk and in legacy cloud blobs
//  carry the per-attachment AES key under `key`, not the modern
//  `encryptionKey`. Decode must read both so a legacy chat can
//  still unseal its attachments after the migration cascade
//  rewrites the metadata. Encode always normalizes to
//  `encryptionKey` so subsequent reads converge on the modern
//  layout.
//

import Foundation
import Testing
@testable import TinfoilChat

@Suite("Attachment legacy key decode")
struct AttachmentLegacyKeyDecodeTests {

    @Test func decodesLegacyKeyFieldIntoEncryptionKey() throws {
        let json = """
        {
          "id": "att-1",
          "type": "image",
          "fileName": "old.png",
          "key": "legacy-base64-key=="
        }
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(attachment.encryptionKey == "legacy-base64-key==")
    }

    @Test func decodesModernEncryptionKeyAsBefore() throws {
        let json = """
        {
          "id": "att-2",
          "type": "document",
          "fileName": "new.pdf",
          "encryptionKey": "modern-base64-key=="
        }
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(attachment.encryptionKey == "modern-base64-key==")
    }

    @Test func prefersModernEncryptionKeyWhenBothPresent() throws {
        let json = """
        {
          "id": "att-3",
          "type": "image",
          "fileName": "both.png",
          "encryptionKey": "modern==",
          "key": "legacy=="
        }
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(attachment.encryptionKey == "modern==")
    }

    @Test func decodesNilWhenNeitherKeyFieldPresent() throws {
        let json = """
        {
          "id": "att-4",
          "type": "image",
          "fileName": "noKey.png"
        }
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(attachment.encryptionKey == nil)
    }

    @Test func reEncodeNormalizesLegacyKeyToEncryptionKey() throws {
        let legacyJSON = """
        {
          "id": "att-5",
          "type": "image",
          "fileName": "round.png",
          "key": "legacy-base64-key=="
        }
        """
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(legacyJSON.utf8))
        let reEncoded = try JSONEncoder().encode(attachment)
        let payload = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        let dict = try #require(payload)
        #expect(dict["encryptionKey"] as? String == "legacy-base64-key==")
        #expect(dict["key"] == nil)
    }
}
