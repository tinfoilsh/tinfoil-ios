import Foundation
import Testing
@testable import TinfoilChat

@Suite("Pinned chat favorites")
struct ChatFavoritesTests {
    @Test("profile JSON preserves missing and explicit empty pins")
    func profileJSONCompatibility() throws {
        let missing = try JSONDecoder().decode(ProfileData.self, from: Data("{}".utf8))
        let empty = try JSONDecoder().decode(
            ProfileData.self,
            from: Data(#"{"pinnedChatIds":[]}"#.utf8)
        )

        #expect(missing.pinnedChatIds == nil)
        #expect(empty.pinnedChatIds == [])

        let encoded = try JSONEncoder().encode(ProfileData(pinnedChatIds: ["chat-a"]))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["pinnedChatIds"] as? [String] == ["chat-a"])
        #expect(object["pinned_chat_ids"] == nil)
    }

    @Test("normalization keeps newest unique ids within the cap")
    func normalizesPinnedIds() {
        let ids = (0...Constants.ChatFavorites.maxPinnedChats).map { "chat-\($0)" }
        let normalized = ChatFavorites.normalize([
            " \(ids[0]) ", ids[0], "\n",
        ] + Array(ids.dropFirst()))

        #expect(normalized.count == Constants.ChatFavorites.maxPinnedChats)
        #expect(normalized.first == ids[0])
        #expect(Set(normalized).count == normalized.count)
    }

    @Test("resolution follows pin order and skips unavailable ids")
    func resolvesInPinnedOrder() {
        struct Favorite: Equatable {
            let id: String
        }
        let values = [Favorite(id: "chat-b"), Favorite(id: "chat-a")]

        let resolved = ChatFavorites.resolve(
            ids: ["chat-a", "missing", "chat-b"],
            from: values,
            id: \.id
        )

        #expect(resolved == [Favorite(id: "chat-a"), Favorite(id: "chat-b")])
    }

    @Test("pruning removes only authoritatively missing ids")
    func prunesConfirmedMissingIds() {
        let pruned = ChatFavorites.removing(
            ["available", "missing", "transient"],
            confirmedMissing: ["missing"]
        )

        #expect(pruned == ["available", "transient"])
    }

    @Test("persistence fencing rejects generation and account changes")
    func fencesFavoritePersistence() {
        let generation = 3
        let nextGeneration = generation + 1
        #expect(ChatFavorites.persistenceRemainsCurrent(
            expectedGeneration: generation,
            currentGeneration: generation,
            expectedUserId: "user-a",
            currentUserId: "user-a"
        ))
        #expect(!ChatFavorites.persistenceRemainsCurrent(
            expectedGeneration: generation,
            currentGeneration: nextGeneration,
            expectedUserId: "user-a",
            currentUserId: "user-a"
        ))
        #expect(!ChatFavorites.persistenceRemainsCurrent(
            expectedGeneration: generation,
            currentGeneration: generation,
            expectedUserId: "user-a",
            currentUserId: "user-b"
        ))
    }

    @Test("only the current per-chat operation owns cleanup")
    func coordinatesPerChatOperationCleanup() {
        #expect(ChatFavorites.operationIsCurrent("current", currentToken: "current"))
        #expect(!ChatFavorites.operationIsCurrent("stale", currentToken: "current"))
        #expect(!ChatFavorites.operationIsCurrent("stale", currentToken: nil as String?))
    }
}
