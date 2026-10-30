//
//  AppConfig.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation

/// The synthetic "Auto" model selection, which has the chat service's router
/// pick a model for each turn at the requested intelligence level.
enum AutoModel {
    static let id = "auto"
    /// Picker ids from the previous two-tier Auto design. They survive in
    /// UserDefaults and inside saved chats, and all resolve to the single
    /// Auto entry.
    static let legacyIds: Set<String> = ["auto-smart", "auto-fast"]

    static func isAutoId(_ id: String) -> Bool {
        id == Self.id || legacyIds.contains(id)
    }
}

/// The positions of the Auto intelligence slider, in the chat service's
/// vocabulary.
enum AutoIntelligence: String, CaseIterable, Codable, Sendable {
    case instant
    case low
    case medium
    case high
    case extra
    case max

    static let `default`: AutoIntelligence = .high

    /// Short label used in the collapsed picker ("Auto · High") and slider.
    var label: String {
        switch self {
        case .instant: return "Instant"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .extra: return "Extra"
        case .max: return "Max"
        }
    }

    var displayName: String { "Auto · \(label)" }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func at(index: Int) -> AutoIntelligence {
        let clamped = Swift.min(Swift.max(index, 0), allCases.count - 1)
        return allCases[clamped]
    }
}

/// Remote configuration structure (mobile-specific settings only)
struct RemoteConfig: Codable {
    let minSupportedVersion: String
}

/// A model as the chat service's session offers it.
struct ModelType: Identifiable, Hashable, Equatable {
    let id: String
    private let model: Components.Schemas.SessionModel

    init(_ model: Components.Schemas.SessionModel) {
        id = model.id
        self.model = model
    }

    private static let autoDescription = "Routes to the best model for the chosen intelligence level"

    /// The entry that has the router choose a model for each turn.
    static let auto = ModelType(Components.Schemas.SessionModel(
        id: AutoModel.id, label: "Auto", shortLabel: "Auto", icon: "",
        description: autoDescription,
        badges: [], reasoning: nil, deprecated: false, auto: true
    ))

    // Display name for UI
    var displayName: String { model.shortLabel }

    // Icon name (from local assets) - derive from image filename
    var iconName: String {
        // Extract icon name from filename like "openai.png"
        let imageName = model.icon.replacingOccurrences(of: ".png", with: "")

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

    var description: String { model.description }

    /// Short blurb for the model picker. The chat service offers Auto
    /// without one, so Auto describes itself.
    var pickerDescription: String {
        isAuto && model.description.isEmpty ? Self.autoDescription : model.description
    }

    // Full model name
    var fullName: String { model.label }

    var responseDisplayName: String { isAuto ? displayName : fullName }

    /// The chat service converts images and documents for every model.
    var isMultimodal: Bool { true }

    var isDeprecated: Bool { model.deprecated }

    var badges: [Components.Schemas.SessionModel.BadgesPayloadPayload] { model.badges }

    // MARK: - Reasoning capabilities

    /// True iff the model exposes any reasoning controls. Used to gate the
    /// reasoning selector visibility.
    var isReasoningModel: Bool { model.reasoning != nil }

    /// True iff the model exposes a graded effort parameter.
    var supportsReasoningEffort: Bool {
        model.reasoning?.effort == true
    }

    /// True iff the model exposes an on/off thinking toggle.
    var supportsThinkingToggle: Bool {
        model.reasoning?.toggle == true
    }

    /// True iff this is the Auto picker entry (or a legacy tier id still
    /// carried by a saved chat).
    var isAuto: Bool { model.auto == true || AutoModel.isAutoId(id) }

    // For Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // For Equatable conformance
    static func == (lhs: ModelType, rhs: ModelType) -> Bool {
        lhs.id == rhs.id
    }
}

/// The app's remote configuration: the version the control plane still
/// supports.
@MainActor
class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @Published private(set) var config: RemoteConfig?
    @Published private(set) var isInitialized = false
    @Published private(set) var initializationError: Error?
    @Published private(set) var networkMonitor = NetworkMonitor()

    private let configURL = Constants.Config.configURL

    private init() {
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
            let (data, _) = try await URLSession.shared.data(from: configURL)
            config = try JSONDecoder().decode(RemoteConfig.self, from: data)
            initializationError = nil
            isInitialized = true
        } catch {
            initializationError = error
        }
    }

    // MARK: - Clerk configuration

    var clerkPublishableKey: String {
        Constants.Clerk.publishableKey
    }

    /// Remote config is only read from views gated behind `isInitialized`,
    /// so a nil config here is a programming error rather than a runtime state.
    private var loadedConfig: RemoteConfig {
        guard let config else {
            preconditionFailure("remote config accessed before initialization")
        }
        return config
    }

    var minSupportedVersion: String {
        loadedConfig.minSupportedVersion
    }

    /// Current app version from bundle
    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Whether the chat service still serves the protocol this app was built
    /// from, as the last session it opened said.
    @Published private(set) var isHarnessProtocolSupported = true

    /// The oldest protocol version the chat service serves, from a session.
    func harnessServes(minimumProtocol minimum: Int) {
        let supported = Constants.Harness.protocolVersion >= minimum
        if supported != isHarnessProtocolSupported { isHarnessProtocolSupported = supported }
    }

    /// The app version required, when this one is older.
    var requiredAppVersion: String? {
        compareVersions(currentAppVersion, minSupportedVersion) == .orderedAscending ? minSupportedVersion : nil
    }

    /// Check if current app version is supported
    var isAppVersionSupported: Bool {
        requiredAppVersion == nil && isHarnessProtocolSupported
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
}
