//
//  ChatForkPolicy.swift
//  TinfoilChat
//

import Foundation

/// Pure decisions behind forking a synced chat through the enclave. Kept
/// free of storage and network so they can be unit-tested directly; the
/// orchestration in `CloudSyncService.forkChat` applies them in order.
enum ChatForkPolicy {
    enum SourceReadiness: Equatable {
        /// The server row already matches the local copy; fork immediately.
        case ready
        /// Local edits have not been uploaded yet; flush before forking.
        case needsFlush
        /// The chat cannot be forked through the enclave at all.
        case ineligible(Reason)

        enum Reason: Equatable {
            case notFound
            case otherAccount
            case localOnly
            case unreadable
            case empty
        }
    }

    /// Whether the local copy of the source is in a state the enclave can
    /// fork from. A locally modified row must be uploaded first or the
    /// enclave would branch from an older revision than the user sees.
    static func sourceReadiness(_ chat: Chat?, activeUserId: String) -> SourceReadiness {
        guard let chat else { return .ineligible(.notFound) }
        guard chat.userId == nil || chat.userId == activeUserId else {
            return .ineligible(.otherAccount)
        }
        guard !chat.isLocalOnly else { return .ineligible(.localOnly) }
        guard !chat.decryptionFailed, !chat.dataCorrupted else {
            return .ineligible(.unreadable)
        }
        guard !chat.messages.isEmpty else { return .ineligible(.empty) }
        return chat.locallyModified ? .needsFlush : .ready
    }

    /// Whether a flush left the source in a forkable state. An edit that
    /// landed during the upload keeps the row dirty; forking then would
    /// silently branch from the older server revision.
    static func isFlushed(_ chat: Chat?) -> Bool {
        guard let chat else { return false }
        return !chat.locallyModified
    }

    /// Whether `messageCount` selects a non-empty prefix of the source.
    static func isValidMessageCount(_ messageCount: Int, sourceMessageCount: Int) -> Bool {
        messageCount >= 1 && messageCount <= sourceMessageCount
    }

    /// The pulled fork as it should be stored locally. The enclave does not
    /// round-trip the model, so the source's model is pinned to keep the
    /// fork from switching models when it replaces the placeholder.
    static func localFork(from pulled: Chat, sourceModel: ModelType) -> Chat {
        var fork = pulled
        fork.modelType = sourceModel
        fork.syncedAt = Date()
        fork.locallyModified = false
        fork.pendingSave = false
        return fork
    }
}
