import Foundation

enum ChatFavorites {
    static func normalize(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(id).inserted
        }
        .prefix(Constants.ChatFavorites.maxPinnedChats)
        .map { $0 }
    }

    static func resolve<Value>(
        ids: [String],
        from values: [Value],
        id: (Value) -> String
    ) -> [Value] {
        let valuesById = Dictionary(values.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { valuesById[$0] }
    }

    static func removing(_ ids: [String], confirmedMissing: Set<String>) -> [String] {
        ids.filter { !confirmedMissing.contains($0) }
    }

    static func persistenceRemainsCurrent(
        expectedGeneration: Int,
        currentGeneration: Int,
        expectedUserId: String,
        currentUserId: String?
    ) -> Bool {
        expectedGeneration == currentGeneration && expectedUserId == currentUserId
    }

    static func operationIsCurrent<Token: Equatable>(
        _ token: Token,
        currentToken: Token?
    ) -> Bool {
        token == currentToken
    }

    static func isPinnable(_ chat: Chat) -> Bool {
        !chat.isLocalOnly
            && !chat.isTemporary
            && !chat.isBlankChat
            && !chat.decryptionFailed
            && !chat.dataCorrupted
    }
}
