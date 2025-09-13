//
//  AppConfig.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation

/// Model configuration for parsing from config json
struct ModelConfig: Codable {
    let id: String
    let displayName: String
    let iconName: String
    let description: String
    let fullName: String
    let modelId: String
    let isFree: Bool
}

/// Remote configuration structure
struct RemoteConfig: Codable {
    let models: [ModelConfig]
    let apiKey: String
    let chatConfig: ChatConfig
    let minSupportedVersion: String
    
    struct ChatConfig: Codable {
        let maxMessagesPerRequest: Int
        let systemPrompt: String
        let rules: String?
    }
}

/// Model type structure to replace enum for dynamic configuration
struct ModelType: Identifiable, Codable, Hashable, Equatable {
    let id: String
    private let config: ModelConfig
    
    init(id: String, config: ModelConfig) {
        self.id = id
        self.config = config
    }
    
    // Display name for UI
    var displayName: String { config.displayName }
    
    // Icon name (from local assets)
    var iconName: String { config.iconName }
    
    // Model description
    var description: String { config.description }
    
    // Full model name
    var fullName: String { config.fullName }
    
    // Additional properties
    var modelNameSimple: String { displayName }
    var modelName: String { config.modelId }
    var image: String { "\(Constants.UI.modelIconPath)\(iconName)\(Constants.UI.modelIconExtension)" }
    var name: String { fullName }
    
    // Add property to check if model is free
    var isFree: Bool { config.isFree }
    
    // For Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // For Equatable conformance
    static func == (lhs: ModelType, rhs: ModelType) -> Bool {
        lhs.id == rhs.id
    }
}

/// Application-wide configuration settings
@MainActor
class AppConfig: ObservableObject {
    static let shared = AppConfig()
    
    @Published private(set) var config: RemoteConfig?
    private let configURL = Constants.Config.configURL
    private let mockConfigURL = Bundle.main.url(forResource: Constants.Config.mockConfigFileName, withExtension: Constants.Config.mockConfigFileExtension)!
    
    // Add initialization state tracking
    @Published private(set) var isInitialized = false
    @Published private(set) var initializationError: Error?
    
    // Current model selection - persisted across app launches
    @Published var currentModel: ModelType? {
        didSet {
            // Persist the selected model to UserDefaults whenever it changes
            if let model = currentModel {
                UserDefaults.standard.set(model.id, forKey: "lastSelectedModel")
            }
        }
    }
    
    // Available models from config
    @Published private(set) var availableModels: [ModelType] = []
    
    // Premium API key flag
    @Published private(set) var isPremiumKeyRequired = false
    
    // Network monitor
    @Published private(set) var networkMonitor = NetworkMonitor()
    
    private init() {
        
        // Load remote configuration
        Task {
            // await loadMockConfig()
            await loadRemoteConfig()
        }
    }
    
    
    func loadRemoteConfig() async {
        do {
            guard networkMonitor.isConnected else {
                initializationError = NSError(
                    domain: Constants.Config.ErrorDomain.domain,
                    code: Constants.Config.ErrorDomain.configNotFoundCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No internet connection",
                        NSLocalizedRecoverySuggestionErrorKey: "Please check your internet connection and try again."
                    ]
                )
                return
            }
            
            let (data, _) = try await URLSession.shared.data(from: configURL)
            let remoteConfig = try JSONDecoder().decode(RemoteConfig.self, from: data)
            
            self.config = remoteConfig
            updateAvailableModels()
            
            // If no current model is set, try to load the last selected model
            if currentModel == nil {
                loadLastSelectedModel()
            }
            
            // Confirm current model is still valid
            if let currentModel = currentModel,
               !availableModels.contains(currentModel) {
                // Fall back to first available model if current is no longer valid
                self.currentModel = availableModels.first
            }
            
            // Clear any previous error
            initializationError = nil
            // Set initialization as complete
            isInitialized = true
        } catch {
            initializationError = error
        }
    }
    
    private func loadMockConfig() {
        do {
            // Try loading from mock_config.json in the bundle
            guard let mockConfigURL = Bundle.main.url(forResource: Constants.Config.mockConfigFileName, withExtension: Constants.Config.mockConfigFileExtension) else {
                let error = NSError(
                    domain: Constants.Config.ErrorDomain.domain,
                    code: Constants.Config.ErrorDomain.configNotFoundCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: Constants.Config.ErrorDomain.configNotFoundDescription,
                        NSLocalizedRecoverySuggestionErrorKey: Constants.Config.ErrorDomain.configNotFoundRecoverySuggestion
                    ]
                )
                initializationError = error
                return
            }
            
            let data = try Data(contentsOf: mockConfigURL)
            config = try JSONDecoder().decode(RemoteConfig.self, from: data)
            
            // Update available models from config
            updateAvailableModels()
            
            // Load last selected model or use first available
            loadLastSelectedModel()
            
            isInitialized = true
        } catch {
            initializationError = error
        }
    }
    
    // Update available models from config
    private func updateAvailableModels() {
        guard let modelConfigs = config?.models else { return }
        availableModels = modelConfigs.map { ModelType(id: $0.id, config: $0) }
    }
    
    // Load the last selected model from UserDefaults
    private func loadLastSelectedModel() {
        if let savedModelId = UserDefaults.standard.string(forKey: "lastSelectedModel"),
           let modelConfig = config?.models.first(where: { $0.id == savedModelId }) {
            currentModel = ModelType(id: savedModelId, config: modelConfig)
        } else {
            // Fall back to first available model
            currentModel = availableModels.first
        }
    }
    
    // MARK: - Public interface
    
    // MARK: - Clerk configuration
   
    var clerkPublishableKey: String {
        Constants.Clerk.publishableKey
    }
    
    // MARK: - Model configuration
    
    func getModelConfig(_ type: ModelType) -> ModelConfig? {
        return config?.models.first { $0.id == type.id }
    }
    
    
    var apiKey: String {
        config!.apiKey
    }
    
    /// Wait for AppConfig to be fully initialized
    func waitForInitialization() async {
        while config == nil {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    /// Get the global API key
    func getApiKey() async -> String {
        return await APIKeyManager.shared.getApiKey()
    }
    
    var maxMessagesPerRequest: Int {
        config!.chatConfig.maxMessagesPerRequest
    }
    
    var systemPrompt: String {
        config!.chatConfig.systemPrompt
    }
    
    var rules: String {
        config?.chatConfig.rules ?? ""
    }
    
    var minSupportedVersion: String {
        config?.minSupportedVersion ?? "1.0.0"
    }
    
    /// Current app version from bundle
    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    
    /// Check if current app version is supported
    var isAppVersionSupported: Bool {
        return compareVersions(currentAppVersion, minSupportedVersion) != .orderedAscending
    }
    
    /// Check if app update is required
    var isUpdateRequired: Bool {
        return !isAppVersionSupported
    }
    
    /// Compare two version strings (e.g., "1.0.5" vs "1.0.3")
    private func compareVersions(_ version1: String, _ version2: String) -> ComparisonResult {
        let components1 = version1.split(separator: ".").compactMap { Int($0) }
        let components2 = version2.split(separator: ".").compactMap { Int($0) }
        
        let maxLength = max(components1.count, components2.count)
        
        for i in 0..<maxLength {
            let v1 = i < components1.count ? components1[i] : 0
            let v2 = i < components2.count ? components2[i] : 0
            
            if v1 < v2 {
                return .orderedAscending
            } else if v1 > v2 {
                return .orderedDescending
            }
        }
        
        return .orderedSame
    }
    
    /// Get model types in the order defined in the config file
    var orderedModelTypes: [ModelType] {
        availableModels
    }
    
    /// Get filtered model types based on authentication status
    func filteredModelTypes(isAuthenticated: Bool, hasActiveSubscription: Bool) -> [ModelType] {
        if isAuthenticated && hasActiveSubscription {
            // Return only premium models for premium users
            return availableModels.filter { !$0.isFree }
        } else {
            // Return all models for non-premium users (they'll see locks on premium ones)
            return availableModels
        }
    }
} 
