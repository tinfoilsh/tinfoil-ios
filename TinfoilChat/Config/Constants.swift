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
    }

    enum API {
        static let chatCompletionsEndpoint = "/v1/chat/completions"
        static let baseURL = "https://api.tinfoil.sh"
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

    enum Sync {
        static let autoSyncIntervalSeconds: TimeInterval = 60.0
        static let clientInitTimeoutSeconds: TimeInterval = 60.0
        static let backgroundTaskName = "CompleteStreamingResponse"
    }

    enum Streaming {
        static let uiUpdateIntervalSeconds: TimeInterval = 0.15
        static let maxUIUpdateIntervalSeconds: TimeInterval = 1.0
    }
}
