//
//  AppConfig.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import OpenAI

/// Per-endpoint enable/disable parameter blocks for thinking mode.
/// Keyed by full endpoint path (e.g. "/v1/chat/completions"). Each block is
/// shallow-merged into the request body when the toggle is in the
/// corresponding state. Mirrors the webapp's `ReasoningEndpointParams`.
///
/// `OpenAIJSON` is the OpenAI SDK's recursive Codable representation of any
/// JSON value, used here to carry arbitrary vendor-specific fields like
/// `chat_template_kwargs` without a typed property per shape. The SDK uses
/// this distinct name so it does not collide with the app's local
/// `JSONValue` enum (used for streaming-event payloads).
struct ReasoningEndpointParams: Codable, Equatable {
    let enable: OpenAIJSON?
    let disable: OpenAIJSON?
}

/// Reasoning capability descriptor returned by the controlplane.
///
/// - `supportsEffort: true` — model accepts a graded effort parameter
///   (low/medium/high).
/// - `supportsToggle: true` — thinking mode can be turned on or off per
///   request via `params[endpoint].enable` / `params[endpoint].disable`.
/// - `defaultEnabled` — initial state of the toggle when `supportsToggle`
///   is true.
/// - `effortMap` — optional translation from the UI's effort vocabulary to
///   the model's actual accepted values (e.g. DeepSeek V4 only accepts
///   `high`/`max`).
/// - `reasoningHistoryPolicy` — controls whether prior assistant reasoning is
///   returned for every assistant message, tool-call messages only, or never.
///
/// The presence of a `reasoningConfig` object is itself the capability
/// flag — there is no separate boolean.
enum ReasoningHistoryPolicy: String, Codable, Equatable {
    case none
    case toolCallOnly = "tool-call-only"
    case all

    private var rank: Int {
        switch self {
        case .none: return 0
        case .toolCallOnly: return 1
        case .all: return 2
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func strongest(_ first: Self, _ second: Self) -> Self {
        second.rank > first.rank ? second : first
    }
}

struct ReasoningConfig: Codable, Equatable {
    let supportsEffort: Bool?
    let supportsToggle: Bool?
    let defaultEnabled: Bool?
    let effortMap: [String: String]?
    let params: [String: ReasoningEndpointParams]?
    let reasoningHistoryPolicy: ReasoningHistoryPolicy?
}

/// Synthetic "Auto" model selection that lets the router pick the best
/// available model and reasoning effort for a requested intelligence level.
/// The request sends `model: "auto"` plus `{ "intelligence": N }` under
/// `AutoModel.optionsField`, mirroring the webapp.
enum AutoModel {
    static let id = "auto"
    static let optionsField = "auto_model_options"
    static let intelligenceKey = "intelligence"

    /// Picker ids from the previous two-tier Auto design. They survive in
    /// UserDefaults and inside saved chats, and all resolve to the single
    /// Auto entry.
    static let legacyIds: Set<String> = ["auto-smart", "auto-fast"]

    static func isAutoId(_ id: String) -> Bool {
        id == Self.id || legacyIds.contains(id)
    }
}

/// The five positions of the Auto intelligence slider. Each maps to a level on
/// the router's normalized 0-100 scale, where 100 is the most capable model and
/// effort currently in the catalog.
enum AutoIntelligence: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case extra
    case max

    static let `default`: AutoIntelligence = .high

    /// Short label used in the collapsed picker ("Auto · High") and slider.
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .extra: return "Extra"
        case .max: return "Max"
        }
    }

    /// Value sent to the router.
    var level: Int {
        switch self {
        case .low: return 0
        case .medium: return 25
        case .high: return 50
        case .extra: return 75
        case .max: return 100
        }
    }

    var displayName: String { "Auto · \(label)" }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func at(index: Int) -> AutoIntelligence {
        let clamped = min(max(index, 0), allCases.count - 1)
        return allCases[clamped]
    }
}

/// Settings the chat clients read for a model. The controlplane sends this
/// block only on chat models and keeps everything a chat client needs inside it.
struct ChatModelConfig: Codable {
    /// Token budget the chat archives history against. May be lower than the
    /// model's raw capability advertised to API consumers.
    let contextWindowTokens: Int?
    /// Open set of model tags advertised by the controlplane (e.g. `smart`, `fast`).
    let attributes: [String]?
    let descriptionShort: String?
    let reasoningConfig: ReasoningConfig?
}

/// Model configuration from the new /api/app/models endpoint
struct AppModelConfig: Codable {
    let modelName: String
    let image: String
    let name: String
    let nameShort: String
    let description: String
    let details: String
    let parameters: String
    let type: String
    let chat: Bool?
    let paid: Bool
    let multimodal: Bool
    let toolCalling: Bool?
    let chatConfig: ChatModelConfig?
}

// The /api/app/models endpoint returns an array directly, not wrapped in an object

/// Remote configuration structure (mobile-specific settings only)
struct RemoteConfig: Codable {
    let chatConfig: ChatConfig
    let minSupportedVersion: String

    struct ChatConfig: Codable {
        let systemPrompt: String
        let rules: String
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
        case "gemma": return "gemma-icon"
        case "zai": return "zai-icon"
        case "nomic": return "default-model-icon" // Use default until we have nomic icon
        default: return "default-model-icon" // Default fallback
        }
    }

    // Model description
    var description: String { appConfig.description }

    /// Short blurb for the model picker, falling back to the full description.
    var pickerDescription: String { appConfig.chatConfig?.descriptionShort ?? appConfig.description }

    // Full model name
    var fullName: String { appConfig.name }

    var responseDisplayName: String { isAuto ? displayName : fullName }

    // Model identifier used for API calls
    var modelName: String { appConfig.modelName }

    // Check if model is free (inverse of paid)
    var isFree: Bool { !appConfig.paid }

    // Additional properties from new config
    var details: String { appConfig.details }
    var parameters: String { appConfig.parameters }
    var contextWindowTokens: Int {
        appConfig.chatConfig?.contextWindowTokens ?? Constants.Context.defaultContextWindowTokens
    }
    var type: String { appConfig.type }
    var isMultimodal: Bool { appConfig.multimodal }
    var isChat: Bool { appConfig.chat ?? (appConfig.type == "chat") }

    // MARK: - Reasoning capabilities

    /// Full reasoning config for this model, or nil if the model is not a
    /// reasoning model.
    var reasoningConfig: ReasoningConfig? { appConfig.chatConfig?.reasoningConfig }

    /// True iff the model exposes any reasoning controls. Used to gate the
    /// reasoning selector visibility.
    var isReasoningModel: Bool { reasoningConfig != nil }

    /// True iff the model exposes a graded effort parameter.
    var supportsReasoningEffort: Bool {
        reasoningConfig?.supportsEffort == true
    }

    /// True iff the model exposes an on/off thinking toggle.
    var supportsThinkingToggle: Bool {
        reasoningConfig?.supportsToggle == true
    }

    var reasoningHistoryPolicy: ReasoningHistoryPolicy {
        reasoningConfig?.reasoningHistoryPolicy ?? .none
    }

    // MARK: - Auto routing

    /// Open set of model tags advertised by the controlplane (e.g. `smart`, `fast`).
    var attributes: [String] { appConfig.chatConfig?.attributes ?? [] }

    /// True iff the model can be picked as an auto candidate for tool use.
    var supportsToolCalling: Bool { appConfig.toolCalling ?? false }

    /// True iff this is the synthetic Auto picker entry (or a legacy tier id
    /// still carried by a saved chat).
    var isAuto: Bool { AutoModel.isAutoId(id) }

    /// Build the synthetic Auto model. Multimodal and tool-calling flags are
    /// unions of the candidate members so the UI and message builder behave
    /// sensibly before the router resolves the request.
    static func auto(members: [ModelType]) -> ModelType {
        let minimumContextMember = members.min {
            $0.contextWindowTokens < $1.contextWindowTokens
        }
        let config = AppModelConfig(
            modelName: AutoModel.id,
            image: "",
            name: "Auto",
            nameShort: "Auto",
            description: "Routes to the best model for the chosen intelligence level",
            details: "",
            parameters: "",
            type: "chat",
            chat: true,
            paid: true,
            multimodal: members.contains { $0.isMultimodal },
            toolCalling: members.contains { $0.supportsToolCalling },
            chatConfig: ChatModelConfig(
                contextWindowTokens: minimumContextMember?.contextWindowTokens,
                attributes: nil,
                descriptionShort: nil,
                reasoningConfig: nil
            )
        )
        return ModelType(from: config)
    }

    // For Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // For Equatable conformance
    static func == (lhs: ModelType, rhs: ModelType) -> Bool {
        lhs.id == rhs.id
    }
}

/// Result of resolving a (possibly Auto) selection into a concrete
/// representative model plus, when Auto, the pool of models the router may
/// choose from. The router makes the actual choice; the client uses the pool
/// only for worst-case budgeting (smallest context window, strongest
/// reasoning history policy).
struct ModelSelection {
    let representative: ModelType
    let autoCandidates: [ModelType]?

    var contextWindowTokens: Int {
        autoCandidates?.map(\.contextWindowTokens).min()
            ?? representative.contextWindowTokens
    }
}

enum ModelAvailability {
    static func realModels(from models: [AppModelConfig]) -> [ModelType] {
        models.filter { model in
            (model.type == "chat" || model.type == "code")
                && model.chat == true
                && !(model.paid == false && model.chat == true)
        }.map { ModelType(from: $0) }
    }

    /// The synthetic Auto entry, present whenever at least one real chat model
    /// exists for the router to choose from.
    static func autoModel(from models: [ModelType]) -> ModelType? {
        models.isEmpty ? nil : ModelType.auto(members: models)
    }

    static func selectableModels(from models: [ModelType]) -> [ModelType] {
        guard let auto = autoModel(from: models) else { return models }
        return [auto] + models
    }

    static func defaultModel(from models: [ModelType]) -> ModelType? {
        autoModel(from: models) ?? models.first
    }

    static func resolveSavedModel(id: String?, from models: [ModelType]) -> ModelType? {
        guard let id else { return defaultModel(from: models) }
        if AutoModel.isAutoId(id) { return autoModel(from: models) ?? defaultModel(from: models) }
        return models.first { $0.id == id } ?? defaultModel(from: models)
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
                UserDefaults.standard.set(model.id, forKey: Constants.StorageKeys.Settings.selectedModel)
            }
        }
    }
    
    // Available models from config
    @Published private(set) var availableModels: [ModelType] = []

    var modelDisplayNamesByName: [String: String] {
        Dictionary(
            availableModels.map { ($0.modelName, $0.fullName) },
            uniquingKeysWith: { first, _ in first }
        )
    }
    
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
        let performanceToken = PerformanceInstrumentation.shared.begin(.remoteConfigLoad)
        defer { PerformanceInstrumentation.shared.end(performanceToken) }
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

            // Fetch config, models, and GenUI config in parallel
            async let configData = URLSession.shared.data(from: configURL)
            async let modelsData = URLSession.shared.data(from: allModelsURL)
            async let genUIRefresh: Void = GenUIConfigService.shared.refresh()

            // Parse config - this is essential, so we need it to succeed
            let (configDataResult, _) = try await configData
            let remoteConfig = try JSONDecoder().decode(RemoteConfig.self, from: configDataResult)

            // Parse models - all endpoints must succeed
            let (modelsDataResult, _) = try await modelsData
            // The API returns an array directly, not wrapped in an object
            let allModels = try JSONDecoder().decode([AppModelConfig].self, from: modelsDataResult)

            try await genUIRefresh

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
               !selectableModels.contains(currentModel) {
                self.currentModel = defaultModel
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
        availableModels = ModelAvailability.realModels(from: appModels)
    }

    // Load the last selected model from UserDefaults
    private func loadLastSelectedModel() {
        let savedModelId = UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.selectedModel)
        currentModel = ModelAvailability.resolveSavedModel(id: savedModelId, from: availableModels)
    }

    // Default selection: Auto, falling back to the first available model when
    // the config carries no chat models to route between.
    var defaultModel: ModelType? {
        ModelAvailability.defaultModel(from: availableModels)
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
    
    /// Remote config is only read from views gated behind `isInitialized`,
    /// so a nil config here is a programming error rather than a runtime state.
    private var loadedConfig: RemoteConfig {
        guard let config else {
            preconditionFailure("remote config accessed before initialization")
        }
        return config
    }
    
    var systemPrompt: String {
        loadedConfig.chatConfig.systemPrompt
    }
    
    var rules: String {
        loadedConfig.chatConfig.rules
    }
    
    var minSupportedVersion: String {
        loadedConfig.minSupportedVersion
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
    
    /// Get all model types available for selection (all models accessible to all users)
    func filteredModelTypes(isAuthenticated: Bool = false, hasActiveSubscription: Bool = false) -> [ModelType] {
        return availableModels
    }

    // MARK: - Auto routing

    func reasoningHistoryPolicy(for model: ModelType) -> ReasoningHistoryPolicy {
        guard model.isAuto else {
            return model.reasoningHistoryPolicy
        }
        return availableModels.reduce(ReasoningHistoryPolicy.none) { policy, candidate in
            ReasoningHistoryPolicy.strongest(policy, candidate.reasoningHistoryPolicy)
        }
    }

    /// The synthetic Auto entry, when any real chat model exists.
    var autoModel: ModelType? {
        ModelAvailability.autoModel(from: availableModels)
    }

    /// Models shown in the picker: Auto first, then real models.
    var selectableModels: [ModelType] {
        ModelAvailability.selectableModels(from: availableModels)
    }

    /// Resolve a selectable id (Auto, a legacy Auto tier id, or real) back to a ModelType.
    func findSelectableModel(id: String) -> ModelType? {
        if AutoModel.isAutoId(id) { return autoModel }
        return availableModels.first { $0.id == id }
    }

    /// Resolve a (possibly Auto) selection into a representative model plus the
    /// pool the router may choose from. Progressive narrowing keeps a
    /// preference only when at least one candidate satisfies it, mirroring the
    /// webapp.
    func resolveModelSelection(
        _ selected: ModelType,
        preferMultimodal: Bool,
        preferToolCalling: Bool
    ) -> ModelSelection {
        guard selected.isAuto else {
            return ModelSelection(representative: selected, autoCandidates: nil)
        }

        var candidates = availableModels
        if preferMultimodal {
            let capable = candidates.filter { $0.isMultimodal }
            if !capable.isEmpty { candidates = capable }
        }
        if preferToolCalling {
            let capable = candidates.filter { $0.supportsToolCalling }
            if !capable.isEmpty { candidates = capable }
        }

        let representative = candidates.first ?? selected
        return ModelSelection(representative: representative, autoCandidates: candidates)
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
