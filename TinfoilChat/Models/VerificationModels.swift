//
//  VerificationModels.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import Foundation
import TinfoilAI

/// UI-specific verification status enum
enum VerifierStatus {
    case pending
    case loading
    case success
    case error
}

/// Extension to convert from VerificationStepState.Status to UI status
extension VerificationStepState.Status {
    var uiStatus: VerifierStatus {
        switch self {
        case .pending:
            return .pending
        case .success:
            return .success
        case .failed:
            return .error
        }
    }
} 
