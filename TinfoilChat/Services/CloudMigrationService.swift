//
//  CloudMigrationService.swift
//  TinfoilChat
//
//  Service for migrating local chats to cloud storage
//

import Foundation

/// Service for migrating old locally stored chats to R2 cloud storage
class CloudMigrationService {
    static let shared = CloudMigrationService()
    
    private let migrationKeyPrefix = "hasCompletedCloudMigration_v1_"
    private let migrationInProgressKey = "cloudMigrationInProgress"
    private let decisionKeyPrefix = "cloudMigrationDecision_v1_" // values: "sync" | "delete"
    
    private func migrationKey(for userId: String?) -> String {
        if let userId = userId {
            return "\(migrationKeyPrefix)\(userId)"
        }
        // For anonymous/legacy data migration
        return "\(migrationKeyPrefix)anonymous"
    }
    
    private init() {}
    
    /// Check if migration is needed and not already completed
    func isMigrationNeeded(userId: String? = nil) -> Bool {
        // Check if migration was already completed for this user
        if UserDefaults.standard.bool(forKey: migrationKey(for: userId)) {
            return false
        }
        
        // Check if there are any old chats in UserDefaults for the current user
        return hasLocalChats(userId: userId)
    }

    // MARK: - User Decision Persistence
    private func decisionKey(for userId: String?) -> String {
        if let userId = userId { return "\(decisionKeyPrefix)\(userId)" }
        return "\(decisionKeyPrefix)anonymous"
    }

    /// Store the user's decision: "sync" or "delete"
    func setUserDecision(_ decision: String, userId: String?) {
        guard decision == "sync" || decision == "delete" else { return }
        UserDefaults.standard.set(decision, forKey: decisionKey(for: userId))
    }

    /// Get the user's decision if previously set
    func getUserDecision(userId: String?) -> String? {
        return UserDefaults.standard.string(forKey: decisionKey(for: userId))
    }

    /// Check whether the user already made a migration choice
    func hasUserMadeDecision(userId: String?) -> Bool {
        return getUserDecision(userId: userId) != nil
    }

    /// Convenience boolean for sync choice
    func didUserChooseSync(userId: String?) -> Bool {
        return getUserDecision(userId: userId) == "sync"
    }
    
    /// Check if there are local chats that need migration for a specific user
    private func hasLocalChats(userId: String?) -> Bool {
        // 1) Check old UserDefaults-based storage (legacy versions)
        if let userId = userId {
            let userKey = "savedChats_\(userId)"
            if UserDefaults.standard.data(forKey: userKey) != nil {
                return true
            }
        }

        let legacyKeys = [
            "savedChats",
            "savedChats_anonymous"
        ]
        for key in legacyKeys {
            if UserDefaults.standard.data(forKey: key) != nil {
                return true
            }
        }

        // 2) Check Keychain-based local storage (recent local-only versions)
        // Anonymous chats (pre-sign-in local history)
        if let anonChats = KeychainChatStorage.shared.loadChats(userId: "anonymous"), !anonChats.isEmpty {
            return true
        }
        // User-scoped local chats that were saved without cloud (defensive check)
        if let userId = userId,
           let userChats = KeychainChatStorage.shared.loadChats(userId: userId), !userChats.isEmpty {
            return true
        }

        return false
    }
    
    /// Perform migration of all local chats to cloud
    func migrateToCloud(userId: String?) async throws -> MigrationResult {
        // Mark migration as in progress
        UserDefaults.standard.set(true, forKey: migrationInProgressKey)
        
        var migratedCount = 0
        var failedCount = 0
        var errors: [String] = []
        
        // Collect all chats from various storage locations
        var allChats: [Chat] = []
        
        // Get chats from legacy keys
        let legacyKeys = ["savedChats", "savedChats_anonymous"]
        for key in legacyKeys {
            if let data = UserDefaults.standard.data(forKey: key) {
                do {
                    let decoder = JSONDecoder()
                    let chats = try decoder.decode([Chat].self, from: data)
                    allChats.append(contentsOf: chats)
                } catch {
                    errors.append("Failed to decode chats from \(key): \(error.localizedDescription)")
                    failedCount += 1
                }
            }
        }
        
        // Get user-specific chats - only migrate chats for the current user
        if let userId = userId {
            let userKey = "savedChats_\(userId)"
            if let data = UserDefaults.standard.data(forKey: userKey) {
                do {
                    let decoder = JSONDecoder()
                    let chats = try decoder.decode([Chat].self, from: data)
                    allChats.append(contentsOf: chats)
                } catch {
                    errors.append("Failed to decode chats from \(userKey): \(error.localizedDescription)")
                    failedCount += 1
                }
            }

            // Also pull any Keychain-stored local chats for this user (defensive)
            if let keychainChats = KeychainChatStorage.shared.loadChats(userId: userId) {
                allChats.append(contentsOf: keychainChats)
            }
        }

        // Also pull any Keychain-stored anonymous chats
        if let anonKeychainChats = KeychainChatStorage.shared.loadChats(userId: "anonymous") {
            allChats.append(contentsOf: anonKeychainChats)
        }
        
        // Remove duplicates based on chat ID
        var seen = Set<String>()
        let uniqueChats = allChats.filter { chat in
            if seen.contains(chat.id) {
                return false
            }
            seen.insert(chat.id)
            return true
        }
        
        // Upload each chat to R2
        for chat in uniqueChats {
            do {
                // Skip if chat has no messages
                guard !chat.messages.isEmpty else {
                    continue
                }
                
                // Ensure we use a server-generated conversation ID for cloud storage
                // If the chat has a temporary (UUID) ID, request a permanent ID from backend
                var chatForUpload: Chat
                if chat.hasTemporaryId {
                    let idResponse = try await R2StorageService.shared.generateConversationId()
                    // Preserve original timestamps and content, just swap the ID
                    chatForUpload = Chat(
                        id: idResponse.conversationId,
                        title: chat.title,
                        messages: chat.messages,
                        createdAt: chat.createdAt,
                        modelType: chat.modelType,
                        language: chat.language,
                        userId: chat.userId,
                        syncVersion: 0,
                        syncedAt: nil,
                        locallyModified: true,
                        updatedAt: chat.updatedAt,
                        decryptionFailed: chat.decryptionFailed,
                        encryptedData: chat.encryptedData
                    )
                } else {
                    chatForUpload = chat
                }

                // Preserve streaming state when reconstructing for upload
                chatForUpload.hasActiveStream = chat.hasActiveStream

                // Create StoredChat format for R2
                let storedChat = StoredChat(from: chatForUpload)
                
                // Upload to R2
                try await R2StorageService.shared.uploadChat(storedChat)
                migratedCount += 1
                
                // Small delay to avoid overwhelming the server
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                
            } catch {
                failedCount += 1
                errors.append("Failed to migrate chat \(chat.id): \(error.localizedDescription)")
            }
        }
        
        // If no failures occurred, mark migration as complete for this user
        if failedCount == 0 {
            cleanupUserDefaults(userId: userId)
            
            // Mark migration as complete for this specific user
            UserDefaults.standard.set(true, forKey: migrationKey(for: userId))
            UserDefaults.standard.removeObject(forKey: migrationInProgressKey)
        } else {
            // Migration failed, don't mark as complete
            UserDefaults.standard.removeObject(forKey: migrationInProgressKey)
        }
        
        return MigrationResult(
            migratedCount: migratedCount,
            failedCount: failedCount,
            errors: errors,
            totalChats: uniqueChats.count
        )
    }
    
    /// Clean up old chat data from UserDefaults
    private func cleanupUserDefaults(userId: String?) {
        // Remove all old chat storage keys (UserDefaults)
        let keysToRemove = [
            "savedChats",
            "savedChats_anonymous"
        ]

        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Remove user-specific key for current user only (UserDefaults)
        if let userId = userId {
            let userKey = "savedChats_\(userId)"
            UserDefaults.standard.removeObject(forKey: userKey)
        }

        // Also clear Keychain-based local storage that we've migrated away from
        KeychainChatStorage.shared.deleteChats(userId: "anonymous")
        if let userId = userId {
            KeychainChatStorage.shared.deleteChats(userId: userId)
        }
    }
    
    /// Reset migration status (useful for testing)
    func resetMigration(userId: String? = nil) {
        if let userId = userId {
            // Reset for specific user
            UserDefaults.standard.removeObject(forKey: migrationKey(for: userId))
        } else {
            // Reset all migration keys
            for key in UserDefaults.standard.dictionaryRepresentation().keys {
                if key.hasPrefix(migrationKeyPrefix) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: migrationInProgressKey)
    }
    
    /// Check if migration is currently in progress
    func isMigrationInProgress() -> Bool {
        return UserDefaults.standard.bool(forKey: migrationInProgressKey)
    }
    
    /// Delete legacy UserDefaults-stored chats without migrating and mark migration complete
    func deleteLegacyLocalChats(userId: String? = nil) {
        // Remove legacy UserDefaults keys
        let keysToRemove = [
            "savedChats",
            "savedChats_anonymous"
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Remove user-specific key for current user only (UserDefaults)
        if let userId = userId {
            let userKey = "savedChats_\(userId)"
            UserDefaults.standard.removeObject(forKey: userKey)
        }

        // Also clear any Keychain-stored local chats
        KeychainChatStorage.shared.deleteChats(userId: "anonymous")
        if let userId = userId {
            KeychainChatStorage.shared.deleteChats(userId: userId)
        }
        // Mark migration as complete so we don't prompt again
        UserDefaults.standard.set(true, forKey: migrationKey(for: userId))
        // Clear any in-progress flag
        UserDefaults.standard.removeObject(forKey: migrationInProgressKey)
    }
}

/// Result of cloud migration operation
struct MigrationResult {
    let migratedCount: Int
    let failedCount: Int
    let errors: [String]
    let totalChats: Int
    
    var isSuccess: Bool {
        return failedCount == 0 && migratedCount > 0
    }
    
    var summary: String {
        if isSuccess {
            return "Successfully migrated \(migratedCount) chat\(migratedCount == 1 ? "" : "s") to cloud storage."
        } else if failedCount > 0 {
            return "Migrated \(migratedCount) of \(totalChats) chats. \(failedCount) failed."
        } else {
            return "No chats to migrate."
        }
    }
}
