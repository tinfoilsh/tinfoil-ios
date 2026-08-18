import Foundation

enum ChatFavorites {
    static func canonicalID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedID(_ id: String) -> String? {
        let normalizedID = canonicalID(id)
        return normalizedID.isEmpty ? nil : normalizedID
    }

    static func normalize(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard let normalizedID = Self.normalizedID(id),
                  seen.insert(normalizedID).inserted else { return nil }
            return normalizedID
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
        isPinnable(
            isLocalOnly: chat.isLocalOnly,
            isTemporary: chat.isTemporary,
            isBlankChat: chat.isBlankChat,
            decryptionFailed: chat.decryptionFailed,
            dataCorrupted: chat.dataCorrupted
        )
    }

    static func isPinnable(_ chat: ChatListSummary) -> Bool {
        isPinnable(
            isLocalOnly: chat.isLocalOnly,
            isTemporary: chat.isTemporary,
            isBlankChat: chat.isBlankChat,
            decryptionFailed: chat.decryptionFailed,
            dataCorrupted: chat.dataCorrupted
        )
    }

    private static func isPinnable(
        isLocalOnly: Bool,
        isTemporary: Bool,
        isBlankChat: Bool,
        decryptionFailed: Bool,
        dataCorrupted: Bool
    ) -> Bool {
        !isLocalOnly
            && !isTemporary
            && !isBlankChat
            && !decryptionFailed
            && !dataCorrupted
    }
}
