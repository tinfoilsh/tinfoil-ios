//
//  SyncEnclaveForkContractTests.swift
//  TinfoilChatTests
//

import Foundation
import Testing
@testable import TinfoilChat

struct SyncEnclaveForkContractTests {
    @Test func forkRequestEncodesTheEnclaveWireShape() throws {
        let request = EnclaveForkRequest(
            sourceId: "chat-source",
            targetId: "chat-fork",
            key: "Y2VrLWJ5dGVz",
            messageCount: 3,
            title: "Trip planning (fork)",
            createdAt: "2026-03-04T05:06:07.123Z",
            idempotencyKey: "fork-1"
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        #expect(object["source_id"] as? String == "chat-source")
        #expect(object["target_id"] as? String == "chat-fork")
        #expect(object["key"] as? String == "Y2VrLWJ5dGVz")
        #expect(object["message_count"] as? Int == 3)
        #expect(object["title"] as? String == "Trip planning (fork)")
        #expect(object["created_at"] as? String == "2026-03-04T05:06:07.123Z")
        #expect(object["idempotency_key"] as? String == "fork-1")
        #expect(object.count == 7)
    }

    @Test func forkResponseDecodesWithAndWithoutSearchIndexed() throws {
        let indexed = try JSONDecoder().decode(
            EnclaveForkResponse.self,
            from: Data(
                #"{"ok":true,"id":"chat-fork","etag":"7","key_id":"ab12","search_indexed":false}"#.utf8
            )
        )
        #expect(indexed.ok)
        #expect(indexed.id == "chat-fork")
        #expect(indexed.etag == "7")
        #expect(indexed.keyId == "ab12")
        #expect(indexed.searchIndexed == false)

        let bare = try JSONDecoder().decode(
            EnclaveForkResponse.self,
            from: Data(#"{"ok":true,"id":"chat-fork","etag":"7","key_id":"ab12"}"#.utf8)
        )
        #expect(bare.searchIndexed == nil)
    }
}
