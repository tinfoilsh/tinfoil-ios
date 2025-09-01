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
    
    private let migrationKey = "hasCompletedCloudMigration_v1"
    private let migrationInProgressKey = "cloudMigrationInProgress"
    
    private init() {}
    
    /// Check if migration is needed and not already completed
    func isMigrationNeeded() -> Bool {
        // Check if migration was already completed
        if UserDefaults.standard.bool(forKey: migrationKey) {
            return false
        }
        
        // Check if there are any old chats in UserDefaults
        return hasLocalChats()
    }
    
    /// Check if there are local chats that need migration
    private func hasLocalChats() -> Bool {
        // Check for various old chat storage keys
        let keysToCheck = [
            "savedChats",
            "savedChats_anonymous"
        ]
        
        // Also check for user-specific keys
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("savedChats_") {
                if UserDefaults.standard.data(forKey: key) != nil {
                    return true
                }
            }
        }
        
        // Check legacy keys
        for key in keysToCheck {
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
                }
            }
        }
        
        // Get user-specific chats
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("savedChats_") && !legacyKeys.contains(key) {
                if let data = UserDefaults.standard.data(forKey: key) {
                    do {
                        let decoder = JSONDecoder()
                        let chats = try decoder.decode([Chat].self, from: data)
                        allChats.append(contentsOf: chats)
                    } catch {
                        errors.append("Failed to decode chats from \(key): \(error.localizedDescription)")
                    }
                }
            }
        }
        
        // Remove duplicates based on chat ID
        let uniqueChats = Array(Set(allChats))
        
        // Upload each chat to R2
        for chat in uniqueChats {
            do {
                // Skip if chat has no messages
                guard !chat.messages.isEmpty else {
                    continue
                }
                
                // Create StoredChat format for R2
                let storedChat = StoredChat(
                    id: chat.id,
                    messages: chat.messages,
                    title: chat.title,
                    createdAt: chat.createdAt,
                    language: chat.language,
                    modelType: chat.modelType
                )
                
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
        
        // If all chats migrated successfully, clean up UserDefaults
        if failedCount == 0 && migratedCount > 0 {
            cleanupUserDefaults()
            
            // Mark migration as complete
            UserDefaults.standard.set(true, forKey: migrationKey)
            UserDefaults.standard.removeObject(forKey: migrationInProgressKey)
        } else if failedCount > 0 {
            // Migration partially failed, don't mark as complete
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
    private func cleanupUserDefaults() {
        // Remove all old chat storage keys
        let keysToRemove = [
            "savedChats",
            "savedChats_anonymous"
        ]
        
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        // Remove user-specific keys
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("savedChats_") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        
        // Synchronize to ensure changes are persisted
        UserDefaults.standard.synchronize()
    }
    
    /// Reset migration status (useful for testing)
    func resetMigration() {
        UserDefaults.standard.removeObject(forKey: migrationKey)
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