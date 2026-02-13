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
        static let chatKeyTTLSeconds: TimeInterval = 300  // 5 minutes
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
        static let enabledKey = "cloudSyncEnabled"
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

    enum Attachments {
        static let maxImageDimension: CGFloat = 768
        static let imageCompressionQuality: CGFloat = 0.85
        static let maxFileSizeBytes: Int64 = 20 * 1024 * 1024      // 20 MB
        static let maxImageSizeBytes: Int64 = 10 * 1024 * 1024     // 10 MB
        static let previewThumbnailSize: CGFloat = 60
        static let previewMaxWidth: CGFloat = 200
        static let messageThumbnailSize: CGFloat = 80
        static let messageThumbnailColumns: Int = 3
        static let supportedDocumentExtensions: Set<String> = ["pdf", "txt", "md", "csv", "html"]
        static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        static let defaultImageMimeType = "image/jpeg"
    }
}
 
