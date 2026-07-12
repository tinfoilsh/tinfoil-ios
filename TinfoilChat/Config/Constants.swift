//
//  Constants.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation

/// Application-wide constants
enum Constants {
    enum Avatar {
        static let primaryColorHex = "004444"
        static let secondaryColorHex = "F9F8F6"
    }

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
        static let tableFontSize: CGFloat = 16
        static let tableCellHorizontalPadding: CGFloat = 12
        static let streamingIndicatorDotSize: CGFloat = 10
        static let streamingIndicatorIconColumnWidth: CGFloat = 16
        static let initFailedContentSpacing: CGFloat = 24
        static let initFailedIconSize: CGFloat = 72
        static let actionButtonCornerRadius: CGFloat = 6
        static let iPadInputBottomPadding: CGFloat = 16
    }

    enum Accessibility {
        /// VoiceOver status announcements posted as generation state changes,
        /// giving non-visual users a live cue equivalent to the web app's
        /// aria-live region.
        static let generatingResponse = "Generating response"
        static let responseComplete = "Response complete"
        static let generationStopped = "Generation stopped"
        static let responseFailed = "Response failed"

        /// Name of the VoiceOver custom rotor used to jump between messages
        /// in the conversation pane.
        static let messagesRotorName = "Messages"

        static let scrollToLatestMessage = "Scroll to latest message"
    }

    enum Rendering {
        /// Code blocks larger than this skip JS-based syntax highlighting
        /// to avoid blocking the main thread via JavaScriptCore.
        static let maxSyntaxHighlightCharacters = 15_000
        /// Messages larger than this skip LaTeX/table regex parsing
        /// and render as plain markdown.
        static let maxFullParsingCharacters = 50_000
        /// Individual markdown segments larger than this are split at
        /// paragraph boundaries to bound CoreText measurement time.
        static let maxMarkdownSegmentCharacters = 8_000
        /// Assistant messages larger than this render without inline text
        /// selection. The selection overlay installs a custom UITextInput per
        /// fragment, which is the most expensive and crash-prone path on long
        /// content; users can still select large messages via the full-text
        /// selection sheet.
        static let maxInlineSelectionCharacters = 10_000
    }

    enum StreamingBuffer {
        static let initialMultiplier: CGFloat = 50.0
        static let multiplierIncrement: CGFloat = 10.0
        static let maxMultiplier: CGFloat = 200.0
        static let extensionThresholdRatio: CGFloat = 0.9
        static let maxCellHeight: CGFloat = 200_000
    }

    /// Heuristics for estimating a message row's height before it has been
    /// measured by the table. Accurate estimates keep the scroll view's
    /// `contentSize` stable while scrolling up through never-displayed rows,
    /// which prevents UIKit from shifting the offset and snapping the view
    /// back toward the bottom.
    enum HeightEstimation {
        /// Horizontal space consumed by cell and bubble padding, subtracted
        /// from the table width to approximate the wrapping text width.
        static let horizontalChrome: CGFloat = 32
        /// Approximate width of one character at the message body font.
        static let averageCharacterWidth: CGFloat = 7.2
        /// Approximate height of one wrapped line of body text.
        static let lineHeight: CGFloat = 20
        /// Vertical padding and chrome around a message's text.
        static let verticalChrome: CGFloat = 56
        /// Extra height for a collapsed reasoning/thoughts pill.
        static let thoughtsHeight: CGFloat = 50
        /// Approximate height contributed by each image attachment.
        static let attachmentHeight: CGFloat = 220
        /// Smallest estimate we ever return for a populated row.
        static let minimumHeight: CGFloat = 60
        /// Fallback estimate used when no message backs the row.
        static let fallbackHeight: CGFloat = 100
    }

    enum Streaming {
        /// Minimum interval between SwiftUI invalidations during a streaming
        /// response. Updating any faster forces SwiftUI to walk a long
        /// environment property list and rebuild the markdown view tree on
        /// every token, which has been observed to either burn the main
        /// thread or grow the AttributeGraph until it aborts on a 256 MB
        /// realloc. 100 ms is fast enough that a reader does not perceive
        /// the throttle while keeping per-second renders bounded.
        static let uiUpdateInterval: TimeInterval = 0.1
    }

    enum API {
        static let chatCompletionsEndpoint = "/v1/chat/completions"
        static let baseURL = "https://api.tinfoil.sh"
        /// Read-only recovery endpoint for passkeys registered on the
        /// pre-enclave (v1) webapp. Consulted only when the enclave key
        /// registry has no usable bundle for this device.
        static let legacyPasskeyCredentialsPath = "/api/passkey-credentials/"
        static let sessionTokenExpiryBufferSeconds: TimeInterval = 300  // 5 minutes

        enum ErrorCode {
            static let invalidAPIKey = "invalid_api_key"
            /// Wire code returned with a 429 when a subscriber exceeds the
            /// per-account hourly inference-token cap.
            static let hourlyLimitReached = "HOURLY_LIMIT_REACHED"
        }
    }

    enum SyncEnclave {
        static let url = "https://sync.tinfoil.sh"
        static let configRepo = "tinfoilsh/confidential-sync"
        static let chatListLimit = 100
        static let projectListLimit = 100
        static let projectChatListLimit = 100
        /// Hard per-page cap the enclave's list-status endpoint
        /// enforces; requests above it are clamped server-side.
        static let listStatusPageLimit = 500
        /// How many full chat blobs to request per pull call. Keeps
        /// individual response payloads bounded when syncing many chats.
        static let pullBatchSize = 20
    }


    enum Legal {
        static let termsOfServiceURL = URL(string: "https://www.tinfoil.sh/terms")!
        static let privacyPolicyURL = URL(string: "https://www.tinfoil.sh/privacy")!
        static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }

    enum PromptLibrary {
        /// Maximum number of prompt presets a user can pin as favorites.
        static let maxFavorites = 3
        /// Number of prompt suggestions shown on the welcome screen.
        static let homeSuggestionCount = 3
    }

    enum Pagination {
        static let chatsPerPage = 20
        static let projectsPerPage = 20
        static let recentChatThresholdSeconds: TimeInterval = 120  // 2 minutes
        static let cleanupThresholdSeconds: TimeInterval = 90     // 1.5 minutes
    }

    enum Context {
        /// Approximate characters per token used by the estimation heuristic.
        static let charsPerToken: Double = 4
        /// Fraction of the model's context window usable by conversation
        /// history. The remainder is headroom for the system prompt and the
        /// model's response. Mirrors the webapp's CONTEXT_WINDOW_USAGE_RATIO.
        static let contextWindowUsageRatio: Double = 0.9
        /// Fallback context window size when a model doesn't report one.
        static let defaultContextWindowTokens = 64_000
        /// Usage percentage at which the context indicator switches to the
        /// warning color.
        static let warningThresholdPercent = 80
    }

    enum CloudSync {
        static let clipboardExpirationSeconds: TimeInterval = 300
    }

    enum Sync {
        static let chatSyncIntervalSeconds: TimeInterval = 20.0
        static let profileSyncIntervalSeconds: TimeInterval = 60.0  // 1 minute
        static let clientInitTimeoutSeconds: TimeInterval = 60.0
        static let backgroundTaskName = "CompleteStreamingResponse"
        static let maxReverseTimestamp: Int = 9999999999999
        static let reverseTimestampDigits: Int = String(maxReverseTimestamp).count

        static let createdAtFallbackThresholdSeconds: TimeInterval = 5.0
        static let uploadBaseDelaySeconds: TimeInterval = 1.0
        static let uploadMaxDelaySeconds: TimeInterval = 8.0
        static let uploadMaxRetries: Int = 3

        // Poll cadence and deadline for the enclave's async
        // migrate-all coordinator. Mirrors the webapp constants so
        // both clients keep the same drain budget.
        static let migrationPollIntervalSeconds: TimeInterval = 2.0
        static let migrationPollTimeoutSeconds: TimeInterval = 15 * 60.0

        // How long sync must stay paused before the UI escalates from
        // the quiet settings status line to the attention badge.
        // Transient network blips and enclave restarts resolve well
        // inside this window; anything longer deserves attention.
        static let pausedAttentionWindowSeconds: TimeInterval = 5 * 60.0
    }

    enum Verification {
        static let networkRetryDelaySeconds: TimeInterval = 2.0
        static let collapseDelaySeconds: TimeInterval = 3.0
    }

    enum Summarizer {
        static let enclaveURL = "https://summarizer.tinfoil.sh"
        static let configRepo = "tinfoilsh/confidential-summarizer"
    }

    enum Metadata {
        static let enclaveURL = "https://opengraph-metadata.tinfoil.sh"
        static let configRepo = "tinfoilsh/confidential-website-metadata-fetcher"
        /// Cap on cached link-metadata entries; favicon bytes ride along
        /// in each entry, so an unbounded cache would grow steadily.
        static let cacheEntryLimit = 200
    }

    enum DocumentProcessing {
        static let enclaveURL = "https://doc-upload.inf9.tinfoil.sh"
        static let configRepo = "tinfoilsh/confidential-doc-upload"
        static let convertPath = "/v1/convert/file"
        static let defaultMode = "text"
    }

    enum ThinkingSummary {
        static let minContentLength = 100
        static let cooldownSeconds: TimeInterval = 3.0
        static let tailWordCount = 200
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

    enum WebApp {
        /// Chat export lives on the web app's cloud-sync settings tab.
        static let exportChatsURL = URL(string: "https://chat.tinfoil.sh/#settings/cloud-sync")!
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
            static let webSearchEnabled = "tinfoil-settings-web-search-enabled"
            static let genUIEnabled = "tinfoil-settings-genui-enabled"
            static let reasoningEffort = "tinfoil-settings-reasoning-effort"
            static let thinkingEnabled = "tinfoil-settings-thinking-enabled"
            static let cloudSyncEnabled = "tinfoil-settings-cloud-sync-enabled"
            static let cloudSyncActiveTab = "tinfoil-settings-cloud-sync-active-tab"
            static let localOnlyModeEnabled = "tinfoil-settings-local-only-mode-enabled"
            static let hasLaunchedBefore = "tinfoil-settings-has-launched-before"
            static let hasSeenPasskeyIntro = "tinfoil-settings-has-seen-passkey-intro"
            static let appLaunchCount = "tinfoil-settings-app-launch-count"
            static let hasSeenReviewPrompt = "tinfoil-settings-has-seen-review-prompt"
            static let hasCompletedOnboarding = "tinfoil-settings-has-completed-onboarding"
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

            static func projectChatStatus(projectId: String) -> String {
                "tinfoil-sync-project-chat-status-\(projectId)"
            }
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
            static let passkeyEnclaveKeyId = "tinfoil-secret-passkey-enclave-key-id"
            static let passkeyEnclaveCredentialId = "tinfoil-secret-passkey-enclave-credential-id"
            static let passkeyRecoveryDismissedKeyId = "tinfoil-secret-passkey-recovery-dismissed-key-id"

            static func cloudKeyAuthorization(userId: String) -> String {
                "tinfoil-secret-cloud-key-authorization-\(userId)"
            }
        }

        // MARK: - One-shot migration flags
        enum Migration {
            /// Set the first time a build evicts locally-cached cloud chats
            /// that the legacy v0/v1 decrypt path used to handle. The enclave
            /// rewraps any orphan rows server-side; the next sync repopulates.
            static let legacyCloudChatsEvicted = "tinfoil-migration-legacy-cloud-chats-evicted"
            /// Per-user fingerprint (suffixed with the clerk user id) of the
            /// migration candidate key set whose last completed sweep left
            /// rows blocked under every key this client holds. While it
            /// matches the current key set the launch sweep is skipped so a
            /// doomed migrate-all is not re-driven every launch; a changed
            /// key set no longer matches and the sweep runs again. Cleared
            /// once a sweep fully migrates with nothing blocked.
            static let migrationExhaustedKeyset = "tinfoil-migration-exhausted-keyset"
        }

        /// Legacy UserDefaults keys that should be purged on app
        /// launch. These named the v1 sync state (passkey JSONB
        /// version counters, the now-removed `passkeyBackedUp`
        /// hint) and have no replacement in the v2 architecture.
        static let legacyKeysToRemove: [String] = [
            "tinfoil-secret-passkey-backed-up",
            "tinfoil-secret-passkey-sync-version",
            "tinfoil-secret-passkey-bundle-version",
            "tinfoil-passkey-backed-up",
            "tinfoil-passkey-sync-version",
        ]
    }

    enum AppReview {
        static let minimumLaunchCount = 5
    }

    enum RateLimit {
        static let warningThreshold = 3
    }

    enum Attachments {
        static let maxImageDimension: CGFloat = 768
        static let imageCompressionQuality: CGFloat = 0.85
        static let maxFileSizeBytes = SharedImportConfiguration.maximumDocumentSizeBytes
        static let maxImageSizeBytes = SharedImportConfiguration.maximumImageSizeBytes
        static let previewThumbnailSize: CGFloat = 60
        static let thumbnailMaxDimension: CGFloat = 300
        static let previewMaxWidth: CGFloat = 200
        static let messageThumbnailSize: CGFloat = 80
        static let messageThumbnailColumns: Int = 3
        static let supportedDocumentExtensions = SharedImportConfiguration.supportedDocumentExtensions
        static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        static let defaultImageMimeType = "image/jpeg"
    }
}

// MARK: - Storage Keys Migration
// One-time migration from old UserDefaults keys to new `tinfoil-` prefixed keys.
enum StorageKeysMigration {
    private static let migrationCompleteKey = "tinfoil-settings-storage-keys-migrated"

    static func migrateIfNeeded() {
        // Purge outside the one-shot guard: users who completed the
        // key-rename migration before this list existed would
        // otherwise keep the stale v1 entries forever. Removing an
        // absent key is a no-op, so re-running every launch is cheap.
        for key in Constants.StorageKeys.legacyKeysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

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
            ("has_seen_passkey_intro", Constants.StorageKeys.Settings.hasSeenPasskeyIntro),
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
 
