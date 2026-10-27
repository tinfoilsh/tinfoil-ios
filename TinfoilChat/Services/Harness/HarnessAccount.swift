import Foundation
import OSLog
import UIKit

/// The settings the harness holds for an account, or this device holds for
/// a signed-in account without cloud sync or a signed-out caller, as a JSON
/// object in the profile's field names. A field left out takes its value
/// from the session's defaults.
typealias ProfileFields = [String: Any]

/// One account's use of the harness: its client, session, content key,
/// quota, settings, and the changes other devices make. A signed-out caller
/// has one too, without an account.
@MainActor
final class HarnessAccount: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Harness")

    let userId: String?
    let client: HarnessClient
    let credentials: HarnessCredentialProvider
    private let keyBytes: @MainActor () -> Data?
    private let settings: ProfileStorage

    @Published private(set) var session: HarnessSession?
    /// The settings as stored, under the changes still being saved.
    @Published private(set) var profile: ProfileFields = [:]
    /// The settings of the current storage mode have loaded.
    @Published private(set) var profileReady = false
    /// The content key is unlocked for the harness's stored chats. A
    /// signed-out caller needs no key.
    @Published private(set) var keyReady = false
    @Published private(set) var keyLocked = false
    /// The harness stores this account's chats and settings. Without cloud
    /// sync, and for a signed-out caller, both stay on this device.
    @Published private(set) var cloud: Bool
    @Published private(set) var error: String?
    /// The account's quota as the session and its runs last reported it.
    @Published private(set) var rateLimit: HarnessRateLimit?
    /// What the harness holds of the account's chats and projects, as a
    /// revision that changes when another device changes them.
    @Published private(set) var chatRevision: String?
    @Published private(set) var projectRevision: String?

    private(set) var disposed = false
    private var cloudSync: Bool
    /// Ends requests that read the content key when the key changes.
    private var keyGeneration = 0
    private var profileVersion = 0
    private var profileWrites: Task<Void, Never>?
    private var profileSource: ProfileSource?
    private var storedProfile: ProfileFields = [:]
    private var unsavedProfile: [ProfileFields] = []
    private var changeTokens: ChangeTokens?
    private var changeWatcher: Task<Void, Never>?
    private var checkingChanges = false
    private var observers: [NSObjectProtocol] = []

    private enum ProfileSource { case cloud, local }

    private struct ChangeTokens: Decodable, Equatable {
        var chats: String
        var profile: String
        var projects: String
    }

    init(
        userId: String?,
        client: HarnessClient,
        credentials: HarnessCredentialProvider,
        keyBytes: @escaping @MainActor () -> Data?,
        settings: ProfileStorage,
        cloudSync: Bool
    ) {
        self.userId = userId
        self.client = client
        self.credentials = credentials
        self.keyBytes = keyBytes
        self.settings = settings
        self.cloudSync = cloudSync
        cloud = userId != nil && cloudSync
        profile = cloud ? settings.cloudProfileCache(userId: userId) : [:]
    }

    func dispose() {
        disposed = true
        changeWatcher?.cancel()
        changeWatcher = nil
        profileWrites?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        Task { await client.dispose() }
    }

    // MARK: - Content key

    /// The account's content key, base64, which a request about its stored
    /// chats carries. A signed-out caller has none.
    func key() throws -> String? {
        guard !disposed else { throw CancellationError() }
        guard userId != nil else { return nil }
        guard var bytes = keyBytes() else {
            throw HarnessError(code: HarnessErrorCode.keyRequired, message: "Unlock your encryption key in Settings to continue.", action: .unlock)
        }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return bytes.base64EncodedString()
    }

    /// The content key changed: requests that read it end, and the settings
    /// load again.
    func invalidateKey() {
        changeTokens = nil
        keyGeneration += 1
        profileVersion += 1
        keyReady = false
        keyLocked = false
        profileReady = false
        showProfile(keptProfile())
    }

    /// The cloud profile this device kept, shown until the harness's loads
    /// and while the key is refused.
    private func keptProfile() -> ProfileFields {
        cloud ? settings.cloudProfileCache(userId: userId) : [:]
    }

    // MARK: - Requests

    /// A request's body with the content key, unless the route reads none.
    private func keyed(_ body: some Encodable, keyless: Bool) throws -> JSONObject {
        var object = try body.jsonObject()
        if !keyless, let key = try key() { object["key"] = key }
        return JSONObject(object)
    }

    private func guardKey(_ generation: Int, keyless: Bool) throws {
        guard !disposed, keyless || generation == keyGeneration else { throw CancellationError() }
    }

    func post<T: Decodable>(_ route: HarnessRoute, _ body: some Encodable = EmptyBody(), keyless: Bool = false, threadId: String? = nil) async throws -> T {
        let generation = keyGeneration
        let result: T = try await client.post(route, try keyed(body, keyless: keyless), threadId: threadId)
        try guardKey(generation, keyless: keyless)
        return result
    }

    func upload<T: Decodable>(_ route: HarnessRoute, file: Data, fileName: String, mimeType: String, fields: [String: String] = [:], keyless: Bool = false) async throws -> T {
        let generation = keyGeneration
        var fields = fields
        if !keyless, let key = try key() { fields["key"] = key }
        let result: T = try await client.upload(route, file: file, fileName: fileName, mimeType: mimeType, fields: fields)
        try guardKey(generation, keyless: keyless)
        return result
    }

    func download(_ route: HarnessRoute, _ body: some Encodable, keyless: Bool = false) async throws -> Data {
        let generation = keyGeneration
        let data = try await client.download(route, try keyed(body, keyless: keyless))
        try guardKey(generation, keyless: keyless)
        return data
    }

    /// A request whose answer streams, such as speech.
    func stream(_ route: HarnessRoute, _ body: some Encodable, keyless: Bool = false) async throws -> HarnessResponse {
        let generation = keyGeneration
        let response = try await client.stream(route, try keyed(body, keyless: keyless))
        try guardKey(generation, keyless: keyless)
        return response
    }

    /// A run's events. The body carries the content key already when the
    /// chat is stored.
    func events(_ route: HarnessRoute, _ body: some Encodable, threadId: String? = nil, lastEventId: Int? = nil) async throws -> AsyncThrowingStream<Frame, Error> {
        guard !disposed else { throw CancellationError() }
        return try await client.events(route, body, threadId: threadId, lastEventId: lastEventId)
    }

    // MARK: - Quota

    /// Shows the quota a session, a run, a refusal or the account's chat
    /// access reported. The harness reports none for a subscriber, whose
    /// quota came with its chat access.
    func reportRateLimit(_ limit: HarnessRateLimit?) {
        guard !disposed, let limit, limit.kind != nil, limit != rateLimit else { return }
        rateLimit = limit
    }

    /// A successful mint may clear the previous quota; a keyless harness
    /// report carries no such authority.
    func reportMintedRateLimit(_ limit: HarnessRateLimit) {
        guard !disposed else { return }
        rateLimit = limit
    }

    /// A run's spend comes off the hourly budget the account's chat access
    /// reported, until the access is minted again with the control plane's
    /// count.
    func reportUsage(_ usage: Components.Schemas.RunMetadata.UsagePayload?) {
        guard !disposed, var limit = rateLimit, limit.kind == .hourly, let usage else { return }
        func spend(_ budget: Components.Schemas.TokenBudget?, _ tokens: Int) -> Components.Schemas.TokenBudget? {
            guard let budget, tokens > 0 else { return budget }
            return Components.Schemas.TokenBudget(max: budget.max, used: budget.used + tokens, remaining: max(0, budget.remaining - tokens))
        }
        limit.inputTokens = spend(limit.inputTokens, usage.promptTokens)
        limit.outputTokens = spend(limit.outputTokens, usage.completionTokens)
        rateLimit = limit
    }

    // MARK: - Session

    /// Opens the app: the session, and the settings of the storage mode.
    @discardableResult
    func refresh(credentials renew: Bool = false) async throws -> HarnessSession {
        if renew { await credentials.resetChatAccess() }
        let session: HarnessSession = try await post(.session, keyless: true)
        guard !disposed else { throw CancellationError() }
        self.session = session
        error = nil
        reportRateLimit(session.rateLimit)
        await refreshProfile()
        return session
    }

    // MARK: - Settings

    /// The members of a profile this client does not read, whose values a
    /// later harness may extend.
    private static let unreadProfileMembers = ["themeMode", "chatFont"]

    /// The settings shown: the session's defaults under the profile. A
    /// profile this client cannot read shows the defaults, and is reported.
    var effectiveProfile: Components.Schemas.Profile {
        var fields = (try? session?.profileDefaults.jsonObject()) ?? [:]
        fields.merge(profile) { $1 }
        for member in Self.unreadProfileMembers { fields[member] = nil }
        do {
            return try Components.Schemas.Profile(jsonObject: fields)
        } catch {
            Self.logger.error("The profile could not be read: \(error, privacy: .public)")
            return Components.Schemas.Profile()
        }
    }

    private func showProfile(_ stored: ProfileFields) {
        storedProfile = stored
        var shown = stored
        for unsaved in unsavedProfile { shown.merge(unsaved) { $1 } }
        profile = shown
    }

    /// Loads the settings of the storage mode. Returns whether they loaded.
    @discardableResult
    func refreshProfile(background: Bool = false) async -> Bool {
        profileVersion += 1
        let version = profileVersion
        if !cloud {
            profileSource = .local
            let local = settings.loadLocalProfile()
            keyReady = userId == nil
            keyLocked = false
            profileReady = true
            error = nil
            showProfile(local)
            await upgradeLocalProfile(local, version: version)
            return true
        }
        if !background {
            keyLocked = false
            error = nil
        }
        do {
            let merging = settings.pendingProfileMerge == userId
            let fields: ProfileFields
            if merging {
                let local = settings.loadLocalProfile()
                let merged: RawJSON = try await post(.profileMerge, JSONObject(["profile": JSONValue(any: local), "changedFields": JSONValue(any: settings.localProfileChanges())]))
                fields = try Self.object(of: merged)
            } else {
                let loaded: RawJSON = try await post(.profileGet)
                fields = try Self.object(of: loaded)
            }
            guard version == profileVersion else { return false }
            if merging {
                settings.clearLocalProfileChanges()
                settings.pendingProfileMerge = nil
            }
            profileSource = .cloud
            keyReady = true
            keyLocked = false
            profileReady = true
            error = nil
            showProfile(fields)
            settings.saveCloudProfileCache(fields, userId: userId)
            return true
        } catch {
            guard !disposed, version == profileVersion else { return false }
            if background {
                Self.logger.error("Failed to refresh the profile: \(error, privacy: .public)")
                return false
            }
            // Only the key's refusal takes the key away; a request that
            // failed for another reason leaves it as it was.
            let keyRefused = (error as? HarnessError).map { $0.code == HarnessErrorCode.keyRequired || $0.code == HarnessErrorCode.keyMismatch } ?? false
            if keyRefused {
                keyReady = false
                keyLocked = true
            }
            profileReady = false
            self.error = error.localizedDescription
            showProfile(keptProfile())
            return false
        }
    }

    /// The harness upgrades a local profile from what older clients stored,
    /// once. A profile changed while it was upgraded is upgraded on a later
    /// load.
    private func upgradeLocalProfile(_ local: ProfileFields, version: Int) async {
        guard !settings.localProfileUpgraded else { return }
        if !local.isEmpty {
            do {
                let sent = try JSONSerialization.data(withJSONObject: local, options: [.sortedKeys])
                let upgraded: RawJSON = try await post(.profileUpgrade, JSONObject(["profile": JSONValue(any: local)]), keyless: true)
                guard !disposed else { return }
                let current = try JSONSerialization.data(withJSONObject: settings.loadLocalProfile(), options: [.sortedKeys])
                guard current == sent else { return }
                let fields = try Self.object(of: upgraded)
                let saved = try settings.saveLocalProfile(fields, replace: true)
                if version == profileVersion { showProfile(saved) }
            } catch {
                guard !disposed else { return }
                report(error)
                return
            }
        }
        settings.localProfileUpgraded = true
    }

    /// Cloud sync was turned on or off. Turning it off keeps the settings the
    /// harness held, as the previous client kept synced settings on the
    /// device.
    func storageModeChanged(cloudSync enabled: Bool) async {
        await profileWrites?.value
        guard !disposed else { return }
        changeTokens = nil
        if !cloud, let userId, enabled { settings.pendingProfileMerge = userId }
        cloudSync = enabled
        cloud = userId != nil && cloudSync
        if !cloud, profileSource == .cloud, profileReady {
            do {
                _ = try settings.saveLocalProfile(profile, replace: true)
                settings.clearLocalProfileChanges()
                settings.localProfileUpgraded = true
            } catch {
                report(error)
            }
        }
        if !cloud {
            settings.pendingProfileMerge = nil
            settings.clearCloudProfileCache(userId: userId)
        }
        invalidateKey()
        await refreshProfile()
    }

    /// A change shows at once. Once saved the view shows the profile the
    /// harness stored under any later changes still being saved; a refused
    /// change is taken back.
    @discardableResult
    func updateProfile(_ patch: ProfileFields) async throws -> ProfileFields {
        guard !disposed else { throw CancellationError() }
        let cloud = cloud
        let generation = keyGeneration
        if unsavedProfile.isEmpty { storedProfile = profile }
        unsavedProfile.append(patch)
        showProfile(storedProfile)
        let previous = profileWrites
        let write = Task { [weak self] () -> Result<ProfileFields, Error> in
            await previous?.value
            guard let self else { return .failure(CancellationError()) }
            do {
                try guardKey(generation, keyless: !cloud)
                profileVersion += 1
                let version = profileVersion
                let saved: ProfileFields
                if cloud {
                    let answer: RawJSON = try await post(.profileUpdate, JSONObject(["patch": JSONValue(any: patch)]))
                    saved = try Self.object(of: answer)
                } else {
                    saved = try settings.saveLocalProfile(patch, replace: false)
                }
                try guardKey(generation, keyless: !cloud)
                settle(patch)
                // A profile read since this change began answers for it later.
                showProfile(version == profileVersion ? saved : storedProfile.merging(patch) { $1 })
                if cloud { settings.saveCloudProfileCache(storedProfile, userId: userId) }
                return .success(saved)
            } catch {
                settle(patch)
                if !disposed { showProfile(storedProfile) }
                return .failure(error)
            }
        }
        profileWrites = Task { _ = await write.value }
        return try await write.value.get()
    }

    private func settle(_ patch: ProfileFields) {
        if let index = unsavedProfile.lastIndex(where: { NSDictionary(dictionary: $0) == NSDictionary(dictionary: patch) }) {
            unsavedProfile.remove(at: index)
        }
    }

    private static func object(of raw: RawJSON) throws -> ProfileFields {
        guard let object = try JSONSerialization.jsonObject(with: raw.data) as? [String: Any] else {
            throw HarnessError.invalidResponse
        }
        return object
    }

    // MARK: - Changes

    /// Polls what the harness holds of the account, so a change another
    /// device made shows here: on a timer, and as the app comes to the
    /// foreground.
    func watchChanges() {
        changeWatcher?.cancel()
        changeWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.Harness.changePollSeconds))
                guard !Task.isCancelled, let self else { return }
                await self.checkChanges()
            }
        }
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { await self?.checkChanges() }
            })
        }
    }

    func checkChanges() async {
        guard !checkingChanges, cloud, keyReady, !disposed, UIApplication.shared.applicationState != .background else { return }
        checkingChanges = true
        defer { checkingChanges = false }
        do {
            var tokens: ChangeTokens = try await post(.changes, keyless: true)
            guard cloud, !disposed else { return }
            if tokens.profile != changeTokens?.profile {
                await profileWrites?.value
                // A profile that could not be read again is asked for on the
                // next check.
                if !(await refreshProfile(background: true)), let known = changeTokens?.profile { tokens.profile = known }
            }
            guard cloud, !disposed else { return }
            changeTokens = tokens
            if tokens.chats != chatRevision { chatRevision = tokens.chats }
            if tokens.projects != projectRevision { projectRevision = tokens.projects }
        } catch {
            if !disposed { Self.logger.error("Failed to refresh remote changes: \(error, privacy: .public)") }
        }
    }

    // MARK: - Errors

    /// Shows why the harness could not complete a request.
    func report(_ cause: Error) {
        guard !disposed, !(cause is CancellationError) else { return }
        error = cause.localizedDescription
        Self.noteAuthenticationRequired(cause)
    }

    /// An identity the harness refused even once refreshed asks for a
    /// sign-in, which the app shows.
    static func noteAuthenticationRequired(_ cause: Error) {
        guard let error = cause as? HarnessError, error.action == .reauthenticate else { return }
        NotificationCenter.default.post(name: .chatAuthenticationRequired, object: nil)
    }
}

/// Where this device keeps the settings the harness does not hold for an
/// account: the local profile and what changed in it, whether it was
/// upgraded, a merge into the cloud still pending, and the cloud profile
/// last seen.
protocol ProfileStorage: AnyObject {
    func loadLocalProfile() -> ProfileFields
    func saveLocalProfile(_ patch: ProfileFields, replace: Bool) throws -> ProfileFields
    func localProfileChanges() -> [String]
    func clearLocalProfileChanges()
    var localProfileUpgraded: Bool { get set }
    var pendingProfileMerge: String? { get set }
    func cloudProfileCache(userId: String?) -> ProfileFields
    func saveCloudProfileCache(_ profile: ProfileFields, userId: String?)
    func clearCloudProfileCache(userId: String?)
}
