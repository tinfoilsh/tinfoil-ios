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
    
    /// Check if there are local chats that need migration for a specific user
    private func hasLocalChats(userId: String?) -> Bool {
        // If we have a userId, only check that user's chats
        if let userId = userId {
            let userKey = "savedChats_\(userId)"
            if UserDefaults.standard.data(forKey: userKey) != nil {
                return true
            }
        }
        
        // Check anonymous/legacy keys (these are not user-specific)
        let legacyKeys = [
            "savedChats",
            "savedChats_anonymous"
        ]
        
        for key in legacyKeys {
            if UserDefaults.standard.data(forKey: key) != nil {
                return true
            }
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
                
                // Create StoredChat format for R2
                let storedChat = StoredChat(from: chat)
                
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
        // Remove all old chat storage keys
        let keysToRemove = [
            "savedChats",
            "savedChats_anonymous"
        ]
        
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        // Remove user-specific key for current user only
        if let userId = userId {
            let userKey = "savedChats_\(userId)"
            UserDefaults.standard.removeObject(forKey: userKey)
        }
        
        // Synchronize to ensure changes are persisted
        UserDefaults.standard.synchronize()
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