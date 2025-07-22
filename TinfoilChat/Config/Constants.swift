//
//  Constants.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import Foundation

/// Application-wide constants
enum Constants {
    enum Clerk {
        static let publishableKey = "pk_live_Y2xlcmsudGluZm9pbC5zaCQ"
    }
    
    enum Config {
        static let configURL = URL(string: "https://api.tinfoil.sh/api/mobile/config")!
        static let mockConfigFileName = "mock_config"
        static let mockConfigFileExtension = "json"
        
        enum ErrorDomain {
            static let domain = "Tinfoil"
            static let configNotFoundCode = 1
            static let configNotFoundDescription = "Configuration file not found"
            static let configNotFoundRecoverySuggestion = "Please check network connection or try again later."
        }
    }
    
    enum UI {
        static let modelIconPath = "/model-icons/"
        static let modelIconExtension = ".png"
    }
    
    enum API {
        static let chatCompletionsEndpoint = "/v1/chat/completions"
        static let endpointProtocol = "https://"
        static let baseURL = "https://api.tinfoil.sh"
    }
    
    
    enum Legal {
        static let termsOfServiceURL = URL(string: "https://www.tinfoil.sh/terms")!
        static let privacyPolicyURL = URL(string: "https://www.tinfoil.sh/privacy")!
        static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }
    
    enum Proxy {
        static let enclaveURL = "inference.tinfoil.sh"
        static let githubRepo = "tinfoilsh/confidential-inference-proxy"
        static let githubReleaseURL = "https://github.com/tinfoilsh/confidential-inference-proxy/releases"
    }
} 
