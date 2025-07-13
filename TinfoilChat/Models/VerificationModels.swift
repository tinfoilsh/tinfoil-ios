//
//  VerificationModels.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.


import Foundation
import TinfoilAI

/// UI-specific verification status enum
enum VerifierStatus {
    case pending
    case loading
    case success
    case error
}

/// Extension to convert from TinfoilAI's VerificationStatus to our UI status
extension VerificationStatus {
    var uiStatus: VerifierStatus {
        switch self {
        case .pending:
            return .pending
        case .inProgress:
            return .loading
        case .success:
            return .success
        case .failure:
            return .error
        }
    }
}

/// Represents a single verification step with its status and details
struct VerificationSectionState {
    var status: VerifierStatus
    var error: String?
    var digest: String?
    var tlsCertificateFingerprint: String?
    var steps: [VerificationStep] = []
}

/// Represents the overall verification state
struct VerificationState {
    var code: VerificationSectionState
    var runtime: VerificationSectionState
    var security: VerificationSectionState
}

/// Represents a single step in the verification process
struct VerificationStep: Identifiable {
    let id = UUID().uuidString
    let text: String
    let link: String?
    
    init(text: String, link: String? = nil) {
        self.text = text
        self.link = link
    }
} 
