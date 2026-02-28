//
//  AppConfig.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation

/// Model configuration from the new /api/app/models endpoint
struct AppModelConfig: Codable {
    let modelName: String
    let image: String
    let repo: String
    let endpoint: String
    let name: String
    let nameShort: String
    let description: String
    let details: String
    let parameters: String
    let contextWindow: String
    let recommendedUse: String
    let supportedLanguages: String
    let type: String
    let chat: Bool?
    let paid: Bool
    let multimodal: Bool
}

// The /api/app/models endpoint returns an array directly, not wrapped in an object

/// Remote configuration structure (mobile-specific settings only)
struct RemoteConfig: Codable {
    let chatConfig: ChatConfig
    let minSupportedVersion: String

    struct ChatConfig: Codable {
        let maxMessagesPerRequest: Int
        let systemPrompt: String?
        let rules: String?
    }
}

/// Model type structure to replace enum for dynamic configuration
struct ModelType: Identifiable, Codable, Hashable, Equatable {
    let id: String
    private let appConfig: AppModelConfig

    init(from appModelConfig: AppModelConfig) {
        self.id = appModelConfig.modelName
        self.appConfig = appModelConfig
    }

    // Display name for UI
    var displayName: String { appConfig.nameShort }

    // Icon name (from local assets) - derive from image filename
    var iconName: String {
        // Extract icon name from filename like "openai.png"
        let imageName = appConfig.image.replacingOccurrences(of: ".png", with: "")

        // Map to iOS icon names
        switch imageName {
        case "openai": return "openai-icon"
        case "deepseek": return "deepseek-icon"
        case "llama": return "llama-icon"
        case "qwen": return "qwen-icon"
        case "mistral": return "mistral-icon"
        case "moonshot": return "moonshot-icon"
        case "nomic": return "default-model-icon" // Use default until we have nomic icon
        default: return "default-model-icon" // Default fallback
        }
    }

    // Model description
    var description: String { appConfig.description }

    // Full model name
    var fullName: String { appConfig.name }

    // Model identifier used for API calls
    var modelName: String { appConfig.modelName }

    // Check if model is free (inverse of paid)
    var isFree: Bool { !appConfig.paid }

    // Additional properties from new config
    var details: String { appConfig.details }
    var parameters: String { appConfig.parameters }
    var contextWindow: String { appConfig.contextWindow }
    var type: String { appConfig.type }
    var isMultimodal: Bool { appConfig.multimodal }
    var isChat: Bool { appConfig.chat ?? (appConfig.type == "chat") }

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
    @Published private(set) var appModels: [AppModelConfig] = []
    private let configURL = Constants.Config.configURL
    private let allModelsURL = Constants.Config.allModelsURL
    
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

            // Fetch config and models in parallel
            async let configData = URLSession.shared.data(from: configURL)
            async let modelsData = URLSession.shared.data(from: allModelsURL)

            // Parse config - this is essential, so we need it to succeed
            let (configDataResult, _) = try await configData
            let remoteConfig = try JSONDecoder().decode(RemoteConfig.self, from: configDataResult)

            // Parse models - both endpoints must succeed
            let (modelsDataResult, _) = try await modelsData
            // The API returns an array directly, not wrapped in an object
            let allModels = try JSONDecoder().decode([AppModelConfig].self, from: modelsDataResult)

            // Store ALL models (including title models for internal use)
            self.appModels = allModels

            self.config = remoteConfig
            updateAvailableModels()

            // If no current model is set, try to load the last selected model or use default
            if currentModel == nil {
                loadLastSelectedModel()
            }

            // Confirm current model is still valid
            if let currentModel = currentModel,
               !availableModels.contains(currentModel) {
                // Fall back to first available model (preferring free model)
                self.currentModel = availableModels.first(where: { $0.isFree }) ?? availableModels.first
            }

            // Clear any previous error
            initializationError = nil
            // Set initialization as complete
            isInitialized = true
        } catch {
            initializationError = error
        }
    }
    
    // Update available models from app models
    private func updateAvailableModels() {
        // Filter models for UI display - exclude title and other non-chat types
        let chatCompatibleModels = appModels.filter { model in
            Self.isModelSupportedInApp(model)
        }
        availableModels = chatCompatibleModels.map { ModelType(from: $0) }
    }

    // Load the last selected model from UserDefaults
    private func loadLastSelectedModel() {
        if let savedModelId = UserDefaults.standard.string(forKey: "lastSelectedModel"),
           let appModel = appModels.first(where: { $0.modelName == savedModelId }) {
            currentModel = ModelType(from: appModel)
        } else {
            // Fall back to first free model, or first available model
            currentModel = availableModels.first(where: { $0.isFree }) ?? availableModels.first
        }
    }
    
    // MARK: - Public interface
    
    // MARK: - Clerk configuration
   
    var clerkPublishableKey: String {
        Constants.Clerk.publishableKey
    }
    
    // MARK: - Model configuration

    /// Wait for AppConfig to be fully initialized
    func waitForInitialization() async {
        while config == nil {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    /// Get the global session token
    func getSessionToken() async -> String {
        return await SessionTokenManager.shared.getSessionToken()
    }
    
    var maxMessagesPerRequest: Int {
        config!.chatConfig.maxMessagesPerRequest
    }
    
    var systemPrompt: String {
        config?.chatConfig.systemPrompt ?? "You are Tin, a helpful AI assistant created by Tinfoil."
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
    
    /// Check if a model should be shown in the app's model selection
    private static func isModelSupportedInApp(_ model: AppModelConfig) -> Bool {
        // Only show models explicitly marked as chat models in the UI
        // Code, title, and other specialized models are not shown

        // Only include models with type "chat"
        return model.type == "chat"
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

    /// Get the title model for generating titles and thinking summaries
    var titleModel: AppModelConfig? {
        appModels.first { $0.type == "title" }
    }

    /// Get the audio model for voice transcription
    var audioModel: AppModelConfig? {
        appModels.first { $0.type == "audio" }
    }
} 
