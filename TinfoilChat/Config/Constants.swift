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

    enum Sync {
        static let chatSyncIntervalSeconds: TimeInterval = 60.0
        static let profileSyncIntervalSeconds: TimeInterval = 300.0  // 5 minutes
        static let clientInitTimeoutSeconds: TimeInterval = 60.0
        static let backgroundTaskName = "CompleteStreamingResponse"
    }

    enum Verification {
        static let networkRetryDelaySeconds: TimeInterval = 2.0
    }

    enum ThinkingSummary {
        static let minContentLength = 100
        static let systemPrompt = "Generate a summary sentence of minimum 5 words, maximum 15 words summarizing the following text. NEVER output markdown."
    }

    enum TitleGeneration {
        static let wordThreshold = 100
        static let systemPrompt = "Generate a concise, descriptive title of minimum 2 words, maximum 5 words for the following text. NEVER output markdown."
    }
}
