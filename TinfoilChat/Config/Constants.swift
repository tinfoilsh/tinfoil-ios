//
//  Constants.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation

/// Application-wide constants
enum Constants {
    enum Clerk {
        static let publishableKey = "pk_live_Y2xlcmsudGluZm9pbC5zaCQ"
    }

    enum Config {
        static let configURL = URL(string: "https://api.tinfoil.sh/api/config/mobile")!
        static let modelsURL = URL(string: "https://api.tinfoil.sh/api/config/models?mobile=true&chat=true")!
        static let allModelsURL = URL(string: "https://api.tinfoil.sh/api/config/models")!

        enum ErrorDomain {
            static let domain = "Tinfoil"
            static let configNotFoundCode = 1
            static let configNotFoundDescription = "Configuration file not found"
            static let configNotFoundRecoverySuggestion = "Please check network connection or try again later."
        }
    }

    enum UI {
        static let scrollToBottomButtonSize: CGFloat = 27
        static let scrollToBottomIconSize: CGFloat = 16
        static let tableMaxColumnWidth: CGFloat = 300
        static let actionButtonCornerRadius: CGFloat = 6
    }

    enum API {
        static let chatCompletionsEndpoint = "/v1/chat/completions"
        static let baseURL = "https://api.tinfoil.sh"
        static let sessionTokenExpiryBufferSeconds: TimeInterval = 300  // 5 minutes

        enum ErrorCode {
            static let invalidAPIKey = "invalid_api_key"
        }
    }


    enum Legal {
        static let termsOfServiceURL = URL(string: "https://www.tinfoil.sh/terms")!
        static let privacyPolicyURL = URL(string: "https://www.tinfoil.sh/privacy")!
        static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }

    enum Pagination {
        static let chatsPerPage = 20
        static let recentChatThresholdSeconds: TimeInterval = 120  // 2 minutes
        static let cleanupThresholdSeconds: TimeInterval = 90     // 1.5 minutes
    }

    enum Context {
        static let defaultMaxMessages = 75
        static let maxMessagesLimit = 200
    }

    enum CloudSync {
        static let clipboardExpirationSeconds: TimeInterval = 300
    }

    enum Sync {
        static let chatSyncIntervalSeconds: TimeInterval = 60.0
        static let profileSyncIntervalSeconds: TimeInterval = 300.0  // 5 minutes
        static let clientInitTimeoutSeconds: TimeInterval = 60.0
        static let backgroundTaskName = "CompleteStreamingResponse"
        static let maxReverseTimestamp: Int = 9999999999999
        static let reverseTimestampDigits: Int = String(maxReverseTimestamp).count

        static let createdAtFallbackThresholdSeconds: TimeInterval = 5.0
        static let uploadBaseDelaySeconds: TimeInterval = 1.0
        static let uploadMaxDelaySeconds: TimeInterval = 8.0
        static let uploadMaxRetries: Int = 3
    }

    enum Verification {
        static let networkRetryDelaySeconds: TimeInterval = 2.0
        static let collapseDelaySeconds: TimeInterval = 3.0
    }

    enum ThinkingSummary {
        static let minContentLength = 100
        static let systemPrompt = "Generate a summary sentence of minimum 5 words, maximum 15 words summarizing the following text. NEVER output markdown."
    }

    enum TitleGeneration {
        static let wordThreshold = 100
        static let systemPrompt = "Generate a concise, descriptive title of minimum 2 words, maximum 5 words for the following text. NEVER output markdown."
    }

    enum Audio {
        static let recordingTimeoutSeconds: TimeInterval = 600  // 10 minutes
        static let sampleRate: Double = 44100.0
        static let numberOfChannels: Int = 1  // Mono
    }

    enum Share {
        static let shareBaseURL = "https://chat.tinfoil.sh"
        static let shareAPIPath = "/api/shares"
        static let encryptionAlgorithm = "AES-GCM"
        static let encryptionKeyBits = 256
        static let ivByteLength = 12
        static let formatVersion = 1
        static let copyFeedbackDurationSeconds: TimeInterval = 2.0
    }

    enum Passkey {
        static let rpId = "tinfoil.sh"
        static let rpName = "Tinfoil Chat"
        static let prfSalt = Data("tinfoil-chat-key-encryption".utf8)
        static let hkdfInfo = Data("tinfoil-chat-kek-v1".utf8)
        static let introDelaySeconds: TimeInterval = 2.0
        static let credentialsEndpoint = "/api/passkey-credentials/"
        static let challengeByteCount = 32
        static let kekByteCount = 32
        static let prfCacheKeychainAccount = "sh.tinfoil.passkey-prf-cache"
        static let syncCheckIntervalSeconds: TimeInterval = 30
    }

    // MARK: - Centralized UserDefaults Storage Keys
    // All keys use lowercase dash-case with a semantic `tinfoil-` prefix.
    // Aligned with the web app's storage-keys.ts where the same data is represented.
    enum StorageKeys {

        // MARK: - Auth
        enum Auth {
            static let state = "tinfoil-auth-state"
            static let userData = "tinfoil-auth-user-data"
            static let subscription = "tinfoil-auth-subscription"
        }

        // MARK: - App Settings
        enum Settings {
            static let selectedModel = "tinfoil-settings-selected-model"
            static let hapticFeedbackEnabled = "tinfoil-settings-haptic-feedback-enabled"
            static let selectedLanguage = "tinfoil-settings-selected-language"
            static let maxPromptMessages = "tinfoil-settings-max-prompt-messages"
            static let webSearchEnabled = "tinfoil-settings-web-search-enabled"
            static let cloudSyncEnabled = "tinfoil-settings-cloud-sync-enabled"
            static let cloudSyncActiveTab = "tinfoil-settings-cloud-sync-active-tab"
            static let localOnlyModeEnabled = "tinfoil-settings-local-only-mode-enabled"
            static let hasLaunchedBefore = "tinfoil-settings-has-launched-before"
            static let hasSeenPasskeyIntro = "tinfoil-settings-has-seen-passkey-intro"
        }

        // MARK: - User Personalization Preferences
        enum UserPrefs {
            static let personalizationEnabled = "tinfoil-user-prefs-personalization-enabled"
            static let nickname = "tinfoil-user-prefs-nickname"
            static let profession = "tinfoil-user-prefs-profession"
            static let traits = "tinfoil-user-prefs-traits"
            static let additionalContext = "tinfoil-user-prefs-additional-context"
            static let customPromptEnabled = "tinfoil-user-prefs-custom-prompt-enabled"
            static let customSystemPrompt = "tinfoil-user-prefs-custom-system-prompt"
        }

        // MARK: - Sync / Data State
        enum Sync {
            static let chatStatus = "tinfoil-sync-chat-status"
            static let allChatsStatus = "tinfoil-sync-all-chats-status"

            static func lastSyncDate(userId: String) -> String {
                "tinfoil-sync-last-sync-date-\(userId)"
            }
            static func paginationToken(userId: String) -> String {
                "tinfoil-sync-pagination-token-\(userId)"
            }
            static func paginationHasMore(userId: String) -> String {
                "tinfoil-sync-pagination-has-more-\(userId)"
            }
            static func paginationActive(userId: String) -> String {
                "tinfoil-sync-pagination-active-\(userId)"
            }
            static func paginationLoadedFirst(userId: String) -> String {
                "tinfoil-sync-pagination-loaded-first-\(userId)"
            }
            static func paginationAttempted(userId: String) -> String {
                "tinfoil-sync-pagination-attempted-\(userId)"
            }
        }

        // MARK: - Secret / Sensitive
        enum Secret {
            static let encryptionKeySetUp = "tinfoil-secret-encryption-key-set-up"
            static let passkeyBackedUp = "tinfoil-secret-passkey-backed-up"
            static let passkeySyncVersion = "tinfoil-secret-passkey-sync-version"
        }
    }

    enum Attachments {
        static let maxImageDimension: CGFloat = 768
        static let imageCompressionQuality: CGFloat = 0.85
        static let maxFileSizeBytes: Int64 = 20 * 1024 * 1024      // 20 MB
        static let maxImageSizeBytes: Int64 = 10 * 1024 * 1024     // 10 MB
        static let previewThumbnailSize: CGFloat = 60
        static let thumbnailMaxDimension: CGFloat = 300
        static let previewMaxWidth: CGFloat = 200
        static let messageThumbnailSize: CGFloat = 80
        static let messageThumbnailColumns: Int = 3
        static let supportedDocumentExtensions: Set<String> = ["pdf", "txt", "md", "csv", "html"]
        static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        static let defaultImageMimeType = "image/jpeg"
    }
}

// MARK: - Storage Keys Migration
// One-time migration from old UserDefaults keys to new `tinfoil-` prefixed keys.
enum StorageKeysMigration {
    private static let migrationCompleteKey = "tinfoil-settings-storage-keys-migrated"

    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationCompleteKey) else { return }

        let migrations: [(old: String, new: String)] = [
            // Auth
            ("sh.tinfoil.authState", Constants.StorageKeys.Auth.state),
            ("sh.tinfoil.userData", Constants.StorageKeys.Auth.userData),
            ("sh.tinfoil.subscription", Constants.StorageKeys.Auth.subscription),
            // Settings
            ("lastSelectedModel", Constants.StorageKeys.Settings.selectedModel),
            ("hapticFeedbackEnabled", Constants.StorageKeys.Settings.hapticFeedbackEnabled),
            ("selectedLanguage", Constants.StorageKeys.Settings.selectedLanguage),
            ("maxPromptMessages", Constants.StorageKeys.Settings.maxPromptMessages),
            ("webSearchEnabled", Constants.StorageKeys.Settings.webSearchEnabled),
            ("cloudSyncEnabled", Constants.StorageKeys.Settings.cloudSyncEnabled),
            ("cloudSyncActiveTab", Constants.StorageKeys.Settings.cloudSyncActiveTab),
            ("localOnlyModeEnabled", Constants.StorageKeys.Settings.localOnlyModeEnabled),
            ("hasLaunchedBefore", Constants.StorageKeys.Settings.hasLaunchedBefore),
            // User prefs
            ("isPersonalizationEnabled", Constants.StorageKeys.UserPrefs.personalizationEnabled),
            ("userNickname", Constants.StorageKeys.UserPrefs.nickname),
            ("userProfession", Constants.StorageKeys.UserPrefs.profession),
            ("userTraits", Constants.StorageKeys.UserPrefs.traits),
            ("userAdditionalContext", Constants.StorageKeys.UserPrefs.additionalContext),
            ("isUsingCustomPrompt", Constants.StorageKeys.UserPrefs.customPromptEnabled),
            ("customSystemPrompt", Constants.StorageKeys.UserPrefs.customSystemPrompt),
            // Sync
            ("tinfoil-chat-sync-status", Constants.StorageKeys.Sync.chatStatus),
            ("tinfoil-all-chats-sync-status", Constants.StorageKeys.Sync.allChatsStatus),
            // Secret / Passkey
            ("encryptionKeyWasSetUp", Constants.StorageKeys.Secret.encryptionKeySetUp),
            ("tinfoil-passkey-backed-up", Constants.StorageKeys.Secret.passkeyBackedUp),
            ("has_seen_passkey_intro", Constants.StorageKeys.Settings.hasSeenPasskeyIntro),
            ("tinfoil-passkey-sync-version", Constants.StorageKeys.Secret.passkeySyncVersion),
        ]

        for (old, new) in migrations where old != new {
            if let value = UserDefaults.standard.object(forKey: old) {
                UserDefaults.standard.set(value, forKey: new)
                UserDefaults.standard.removeObject(forKey: old)
            }
        }

        UserDefaults.standard.set(true, forKey: migrationCompleteKey)
    }
}
 
