//
//  Model+Tinfoil.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation

/// Helper for working with model IDs
/// Note: With TinfoilAI, model IDs are used directly as strings
@MainActor
struct TinfoilModel {
    /// Get the current model ID as a string
    static var currentModelId: String {
        get async {
            let currentModel = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first!
            return currentModel.modelName
        }
    }
    
    /// Get a model ID for a specific ModelType
    static func getModelId(for modelType: ModelType) -> String {
        // Use the modelName property directly from ModelType
        return modelType.modelName
    }
} 
