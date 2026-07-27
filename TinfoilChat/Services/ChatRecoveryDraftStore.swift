import Combine
import Foundation

struct ChatRecoveryDraftKey: Hashable {
    let chatId: String
    let turnId: String
}

@MainActor
final class ChatRecoveryDraftStore: ObservableObject {
    static let shared = ChatRecoveryDraftStore()

    @Published private(set) var drafts: [ChatRecoveryDraftKey: Message] = [:]
    private var accountGeneration = 0
    private var scanGeneration = 0
    private var discardedChatIds: Set<String> = []
    private var discardedKeys: Set<ChatRecoveryDraftKey> = []

    init() {}

    func replace(
        _ draft: Message,
        chatId: String,
        turnId: String,
        generation: Int,
        scanGeneration: Int? = nil
    ) {
        let key = ChatRecoveryDraftKey(chatId: chatId, turnId: turnId)
        guard generation == accountGeneration,
              scanGeneration == nil || scanGeneration == self.scanGeneration,
              !discardedChatIds.contains(chatId),
              !discardedKeys.contains(key)
        else {
            return
        }
        var streamingDraft = draft
        streamingDraft.turnId = turnId
        streamingDraft.isStreaming = true
        guard drafts[key] != streamingDraft else { return }
        drafts[key] = streamingDraft
    }

    func beginScan(generation: Int) {
        guard generation >= scanGeneration else { return }
        scanGeneration = generation
    }

    func clear(chatId: String, turnId: String) {
        let key = ChatRecoveryDraftKey(
            chatId: chatId,
            turnId: turnId
        )
        guard drafts[key] != nil else { return }
        drafts.removeValue(forKey: key)
    }

    func prune(chatId: String, retaining turnIds: Set<String>) {
        let pruned = drafts.filter { key, _ in
            key.chatId != chatId || turnIds.contains(key.turnId)
        }
        guard pruned != drafts else { return }
        drafts = pruned
    }

    func reset(generation: Int) {
        guard generation >= accountGeneration else { return }
        accountGeneration = generation
        scanGeneration = 0
        discardedChatIds.removeAll()
        discardedKeys.removeAll()
        clearAll()
    }

    func discard(chatId: String) {
        discardedChatIds.insert(chatId)
        prune(chatId: chatId, retaining: [])
    }

    func discard(chatId: String, turnId: String) {
        let key = ChatRecoveryDraftKey(chatId: chatId, turnId: turnId)
        discardedKeys.insert(key)
        clear(chatId: chatId, turnId: turnId)
    }

    func allow(chatId: String, turnId: String) {
        discardedKeys.remove(
            ChatRecoveryDraftKey(chatId: chatId, turnId: turnId)
        )
    }

    func clearAll() {
        guard !drafts.isEmpty else { return }
        drafts.removeAll()
    }
}

func messagesApplyingRecoveryDrafts(
    _ messages: [Message],
    chatId: String,
    pendingTurnIds: Set<String>,
    drafts: [ChatRecoveryDraftKey: Message]
) -> [Message] {
    guard !pendingTurnIds.isEmpty, !drafts.isEmpty else { return messages }
    let draftsByTurnId: [String: Message] = Dictionary(
        uniqueKeysWithValues: drafts.compactMap { key, draft -> (String, Message)? in
            guard key.chatId == chatId, pendingTurnIds.contains(key.turnId) else {
                return nil
            }
            return (key.turnId, draft)
        }
    )
    guard !draftsByTurnId.isEmpty else { return messages }

    let persistedAssistantTurnIds: Set<String> = Set(messages.compactMap { message -> String? in
        guard message.role == .assistant else { return nil }
        return message.turnId
    })
    var result: [Message] = []
    result.reserveCapacity(messages.count + draftsByTurnId.count)

    for message in messages {
        guard let turnId = message.turnId,
              let draft = draftsByTurnId[turnId]
        else {
            result.append(message)
            continue
        }

        if message.role == .assistant {
            result.append(recoveryDraftPresentationMessage(
                draft,
                id: message.id,
                timestamp: message.timestamp
            ))
        } else {
            result.append(message)
            if message.role == .user,
               !persistedAssistantTurnIds.contains(turnId) {
                result.append(recoveryDraftPresentationMessage(
                    draft,
                    id: recoveryDraftMessageId(chatId: chatId, turnId: turnId),
                    timestamp: message.timestamp
                ))
            }
        }
    }
    return result
}

func recoveryDraftMessageId(chatId: String, turnId: String) -> String {
    "recovery-draft:\(chatId):\(turnId)"
}

private func recoveryDraftPresentationMessage(
    _ draft: Message,
    id: String,
    timestamp: Date
) -> Message {
    var message = Message(
        id: id,
        role: .assistant,
        turnId: draft.turnId,
        content: draft.content,
        thoughts: draft.thoughts,
        isThinking: draft.isThinking,
        timestamp: timestamp,
        isCollapsed: draft.isCollapsed,
        generationTimeSeconds: draft.generationTimeSeconds,
        contentChunks: draft.contentChunks,
        thinkingChunks: draft.thinkingChunks,
        webSearchState: draft.webSearchState,
        attachments: draft.attachments
    )
    message.isStreaming = true
    message.streamError = draft.streamError
    message.isRequestError = draft.isRequestError
    message.isRateLimitError = draft.isRateLimitError
    message.isHourlyLimitError = draft.isHourlyLimitError
    message.isConnectionError = draft.isConnectionError
    message.urlFetches = draft.urlFetches
    message.thinkingDuration = draft.thinkingDuration
    message.isError = draft.isError
    message.webSearchBeforeThinking = draft.webSearchBeforeThinking
    message.annotations = draft.annotations
    message.searchReasoning = draft.searchReasoning
    message.segments = draft.segments
    message.webSearches = draft.webSearches
    message.toolCalls = draft.toolCalls
    message.timeline = draft.timeline
    return message
}
