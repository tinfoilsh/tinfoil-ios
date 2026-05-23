//
//  LegacyChatEviction.swift
//  TinfoilChat
//
//  One-shot cleanup that runs the first time a build with the
//  enclave-only sync path launches. The legacy v0/v1 client-side
//  decrypt code is gone, so any locally cached cloud chats that
//  are flagged decryptionFailed (or were stored under an older
//  format version) are now unreadable and would shadow the live
//  enclave-rewrapped copy. Dropping them lets the next sync pull
//  fresh plaintext from the enclave.
//

import Foundation

enum LegacyChatEviction {
    /// Idempotent: keyed off a UserDefaults flag so callers can
    /// invoke it on every launch without paying for the disk walk
    /// twice. Local-only chats (DeviceEncryptionService) are left
    /// alone because they were never tangled up in the cloud key.
    static func runIfNeeded(userId: String?) async {
        guard let userId, !userId.isEmpty else { return }
        let defaults = UserDefaults.standard
        // Scope the one-shot flag per user so signing in as a second
        // local account re-runs the eviction for that user's cache.
        let flagKey = Constants.StorageKeys.Migration.legacyCloudChatsEvicted + "_" + userId
        guard !defaults.bool(forKey: flagKey) else { return }

        let storage = EncryptedFileStorage.cloud
        let chats: [Chat]
        do {
            chats = try await storage.loadAllChats(userId: userId)
        } catch {
            return
        }

        var allDeletesSucceeded = true
        for chat in chats where shouldEvict(chat) {
            do {
                try await storage.deleteChat(chatId: chat.id, userId: userId)
            } catch {
                allDeletesSucceeded = false
            }
        }

        // Only mark the migration complete when every targeted chat
        // was actually evicted; a partial failure should re-run on
        // next launch so the orphan rows don't survive forever.
        if allDeletesSucceeded {
            defaults.set(true, forKey: flagKey)
        }
    }

    private static func shouldEvict(_ chat: Chat) -> Bool {
        if chat.decryptionFailed { return true }
        if let version = chat.formatVersion, version < 2 { return true }
        return false
    }
}
