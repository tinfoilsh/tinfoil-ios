//
//  ProfileManager.swift
//  TinfoilChat
//
//  The account's settings as the views bind to them. The chat service holds
//  the profile, or this device does for an account without cloud sync and
//  for a signed-out caller; the account's session keeps either, and this
//  mirrors it and writes the user's changes back as patches.
//

import Combine
import Foundation
import OSLog

enum ProfileDefaults {
    static let language = ResponseLanguageResolver.systemSelection
    static let nickname = ""
    static let profession = ""
    static let traits: [String] = []
    static let additionalContext = ""
    static let isUsingPersonalization = true
    static let customPromptPresets: [SyncedPromptPreset] = []
    static let favoritePromptPresetIds: [String] = []
    static let defaultPromptPresetId = ""
    static let webSearchAvailable = true
    static let piiCheckEnabled = true
    static let genUIEnabled = true
}

/// A prompt the user saved, as the profile stores it. Field names are part
/// of the wire format shared with the web app.
struct SyncedPromptPreset: Codable, Equatable {
    var id: String
    var name: String
    var description: String
    var systemPrompt: String
    var createdAt: Double
    var updatedAt: Double
    /// Optional chat settings applied once when the preset is selected for a
    /// chat. Nil means "leave the chat as is".
    var model: String?
    var webSearchEnabled: Bool?

    init(
        id: String,
        name: String,
        description: String,
        systemPrompt: String,
        createdAt: Double,
        updatedAt: Double,
        model: String? = nil,
        webSearchEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.webSearchEnabled = webSearchEnabled
    }

    init(_ preset: Components.Schemas.CustomPreset) {
        id = preset.id
        name = preset.name
        description = preset.description ?? ""
        systemPrompt = preset.systemPrompt ?? ""
        createdAt = Self.millis(preset.createdAt)
        updatedAt = Self.millis(preset.updatedAt)
        model = preset.model
        webSearchEnabled = preset.webSearchEnabled
    }

    /// A timestamp as a client wrote it: epoch milliseconds, or a date.
    private static func millis(_ value: Components.Schemas.Json?) -> Double {
        switch value?.value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let text as String: return (ChatAccessCache.date(of: text)?.timeIntervalSince1970 ?? 0) * 1000
        default: return 0
        }
    }
}

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Profile")

    @Published private(set) var language: String = ProfileDefaults.language
    @Published private(set) var nickname: String = ProfileDefaults.nickname
    @Published private(set) var profession: String = ProfileDefaults.profession
    @Published private(set) var traits: [String] = ProfileDefaults.traits
    @Published private(set) var additionalContext: String = ProfileDefaults.additionalContext
    @Published private(set) var isUsingPersonalization: Bool = ProfileDefaults.isUsingPersonalization
    @Published private(set) var customPromptPresets: [SyncedPromptPreset] = ProfileDefaults.customPromptPresets
    @Published private(set) var favoritePromptPresetIds: [String] = ProfileDefaults.favoritePromptPresetIds
    @Published private(set) var defaultPromptPresetId: String = ProfileDefaults.defaultPromptPresetId
    @Published private(set) var webSearchAvailable: Bool = ProfileDefaults.webSearchAvailable
    @Published private(set) var piiCheckEnabled: Bool = ProfileDefaults.piiCheckEnabled
    @Published private(set) var genUIEnabled: Bool = ProfileDefaults.genUIEnabled

    private weak var account: HarnessAccount?
    private var cancellable: AnyCancellable?

    private init() {}

    /// Mirrors the account's profile, as its session keeps it.
    func bind(_ account: HarnessAccount?) {
        cancellable?.cancel()
        self.account = account
        guard let account else {
            apply(Components.Schemas.Profile())
            return
        }
        cancellable = Publishers.CombineLatest(account.$profile, account.$session)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self, let account = self.account else { return }
                apply(account.effectiveProfile)
            }
    }

    private func apply(_ profile: Components.Schemas.Profile) {
        language = profile.language ?? ProfileDefaults.language
        nickname = profile.nickname ?? ProfileDefaults.nickname
        profession = profile.profession ?? ProfileDefaults.profession
        traits = profile.traits ?? ProfileDefaults.traits
        additionalContext = profile.additionalContext ?? ProfileDefaults.additionalContext
        isUsingPersonalization = profile.isUsingPersonalization ?? ProfileDefaults.isUsingPersonalization
        customPromptPresets = (profile.customPromptPresets ?? []).map(SyncedPromptPreset.init)
        favoritePromptPresetIds = profile.favoritePromptPresetIds ?? ProfileDefaults.favoritePromptPresetIds
        defaultPromptPresetId = profile.defaultPromptPresetId ?? ProfileDefaults.defaultPromptPresetId
        webSearchAvailable = profile.webSearchAvailable ?? ProfileDefaults.webSearchAvailable
        piiCheckEnabled = profile.piiCheckEnabled ?? ProfileDefaults.piiCheckEnabled
        genUIEnabled = profile.genUIEnabled ?? ProfileDefaults.genUIEnabled
    }

    /// Saves a change to the profile. The change shows at once through the
    /// account's session; one the chat service refuses is taken back, and
    /// logged here.
    private func save(_ patch: ProfileFields) {
        guard let account else { return }
        Task {
            do {
                try await account.updateProfile(patch)
            } catch {
                guard !(error is CancellationError) else { return }
                Self.logger.error("Failed to save the profile: \(error, privacy: .public)")
            }
        }
    }

    private static func encoded<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])) ?? NSNull()
    }

    // MARK: - Settings

    func setLanguage(_ language: String) {
        guard language != self.language else { return }
        self.language = language
        save(["language": language])
    }

    func setWebSearchAvailable(_ available: Bool) {
        guard available != webSearchAvailable else { return }
        webSearchAvailable = available
        save(["webSearchAvailable": available])
    }

    func setPIICheckEnabled(_ enabled: Bool) {
        guard enabled != piiCheckEnabled else { return }
        piiCheckEnabled = enabled
        save(["piiCheckEnabled": enabled])
    }

    func setGenUIEnabled(_ enabled: Bool) {
        guard enabled != genUIEnabled else { return }
        genUIEnabled = enabled
        save(["genUIEnabled": enabled])
    }

    var personalizationDraft: PersonalizationDraft {
        PersonalizationDraft(
            isEnabled: isUsingPersonalization,
            nickname: nickname,
            profession: profession,
            traits: traits,
            additionalContext: additionalContext
        )
    }

    /// Saves the personalization, or throws what refused it; the account's
    /// session then shows the settings as they were.
    func savePersonalization(_ draft: PersonalizationDraft) async throws {
        guard let account else { throw HarnessError.unauthenticated }
        let before = personalizationDraft
        showPersonalization(draft)
        do {
            try await account.updateProfile([
                "isUsingPersonalization": draft.isEnabled,
                "nickname": draft.nickname,
                "profession": draft.profession,
                "traits": draft.traits,
                "additionalContext": draft.additionalContext,
            ])
        } catch {
            if personalizationDraft == draft { showPersonalization(before) }
            throw error
        }
    }

    private func showPersonalization(_ draft: PersonalizationDraft) {
        isUsingPersonalization = draft.isEnabled
        nickname = draft.nickname
        profession = draft.profession
        traits = draft.traits
        additionalContext = draft.additionalContext
    }

    // MARK: - Prompt Presets

    /// All presets surfaced in the prompt library: built-ins followed by the
    /// user's custom presets.
    var allPromptPresets: [PromptPreset] {
        PromptPreset.builtIns + customPromptPresets.map { PromptPreset(from: $0) }
    }

    /// Resolve a preset by id across built-ins and user presets.
    func promptPreset(for id: String?) -> PromptPreset? {
        guard let id else { return nil }
        return allPromptPresets.first { $0.id == id }
    }

    private func generatePresetId() -> String {
        let random = UUID().uuidString.prefix(8).lowercased()
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        return "\(PromptPreset.userIdPrefix)\(timestamp)-\(random)"
    }

    private func savePresets() {
        save(["customPromptPresets": Self.encoded(customPromptPresets)])
    }

    /// Create a new user preset and return its library representation.
    @discardableResult
    func createPromptPreset(
        name: String,
        description: String,
        systemPrompt: String,
        model: String? = nil,
        webSearchEnabled: Bool? = nil
    ) -> PromptPreset {
        let now = Date().timeIntervalSince1970 * 1000
        let preset = SyncedPromptPreset(
            id: generatePresetId(),
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            createdAt: now,
            updatedAt: now,
            model: model,
            webSearchEnabled: webSearchEnabled
        )
        customPromptPresets.append(preset)
        savePresets()
        return PromptPreset(from: preset)
    }

    /// Update an existing user preset in place.
    func updatePromptPreset(
        id: String,
        name: String,
        description: String,
        systemPrompt: String,
        model: String?,
        webSearchEnabled: Bool?
    ) {
        guard let index = customPromptPresets.firstIndex(where: { $0.id == id }) else { return }
        customPromptPresets[index].name = name
        customPromptPresets[index].description = description
        customPromptPresets[index].systemPrompt = systemPrompt
        customPromptPresets[index].model = model
        customPromptPresets[index].webSearchEnabled = webSearchEnabled
        customPromptPresets[index].updatedAt = Date().timeIntervalSince1970 * 1000
        savePresets()
    }

    /// Delete a user preset.
    func deletePromptPreset(id: String) {
        customPromptPresets.removeAll { $0.id == id }
        favoritePromptPresetIds.removeAll { $0 == id }
        var patch: ProfileFields = [
            "customPromptPresets": Self.encoded(customPromptPresets),
            "favoritePromptPresetIds": favoritePromptPresetIds,
        ]
        if defaultPromptPresetId == id {
            defaultPromptPresetId = ProfileDefaults.defaultPromptPresetId
            patch["defaultPromptPresetId"] = defaultPromptPresetId
        }
        save(patch)
    }

    // MARK: - Default Preset

    /// The preset new chats start with, or nil for the Tinfoil default. A
    /// stale id (preset deleted elsewhere or not yet synced here) resolves to
    /// nil so new chats fall back to the default instead of a missing preset.
    var defaultPromptPreset: PromptPreset? {
        promptPreset(for: defaultPromptPresetId.isEmpty ? nil : defaultPromptPresetId)
    }

    func isDefaultPreset(_ id: String) -> Bool {
        defaultPromptPresetId == id
    }

    /// Make a preset the default for new chats, or clear the default when
    /// nil is passed.
    func setDefaultPromptPreset(_ id: String?) {
        defaultPromptPresetId = id ?? ProfileDefaults.defaultPromptPresetId
        save(["defaultPromptPresetId": defaultPromptPresetId])
    }

    // MARK: - Favorites

    /// Presets pinned as homescreen favorites, resolved in pinned order.
    /// Ids that no longer resolve (e.g. a deleted custom preset synced from
    /// another device) are skipped.
    var favoritePromptPresets: [PromptPreset] {
        favoritePromptPresetIds.compactMap { promptPreset(for: $0) }
    }

    func isFavoritePreset(_ id: String) -> Bool {
        favoritePromptPresetIds.contains(id)
    }

    /// Whether another preset can still be pinned given the favorites cap.
    /// Capacity is measured against favorites that actually resolve to a
    /// preset, so stale ids never count toward the cap and block adding a
    /// valid favorite.
    var canAddFavorite: Bool {
        favoritePromptPresets.count < Constants.PromptLibrary.maxFavorites
    }

    /// Whether the favorite toggle for a preset should be enabled: already
    /// pinned presets can always be unpinned, others only while under the cap.
    func canToggleFavorite(_ id: String) -> Bool {
        isFavoritePreset(id) || canAddFavorite
    }

    /// Toggle a preset's favorite status. Pinning is ignored once the cap is
    /// reached; unpinning always works.
    func toggleFavoritePreset(_ id: String) {
        if let index = favoritePromptPresetIds.firstIndex(of: id) {
            favoritePromptPresetIds.remove(at: index)
        } else if canAddFavorite {
            favoritePromptPresetIds.append(id)
        } else {
            return
        }
        save(["favoritePromptPresetIds": favoritePromptPresetIds])
    }

    /// Duplicate a built-in or user preset into a new editable user preset.
    @discardableResult
    func duplicatePromptPreset(id: String) -> PromptPreset? {
        guard let source = promptPreset(for: id) else { return nil }
        return createPromptPreset(
            name: "\(source.name) (copy)",
            description: source.description,
            systemPrompt: source.systemPrompt,
            model: source.model,
            webSearchEnabled: source.webSearchEnabled
        )
    }

    // MARK: - Account removal

    /// Forgets the settings this device kept for the account.
    func clearLocalProfileForAccountRemoval() {
        let storage = DeviceProfileStorage()
        storage.clearLocalProfile()
        if let userId = account?.userId { storage.clearCloudProfileCache(userId: userId) }
        apply(Components.Schemas.Profile())
    }
}
