//
//  ChatViewModel.swift
//  TinfoilChat
//
//  What the chat views bind to. The chat service runs every chat; the view
//  model opens the account's session with it, shows the open chat and the
//  chat list, and keeps the state only the app has: what is picked, shown
//  and recorded.
//

import AVFoundation
import Combine
import Foundation
import OSLog
import SwiftUI
import TinfoilAI
import VisionKit

enum ChatStorageTab: String, Sendable, Hashable {
    case cloud
    case local
}

enum ChatNavigationDestination: Hashable {
    case chat
    case projects
    case favorites
}

struct ChatNavigationRequest: Equatable {
    let id = UUID()
    let destination: ChatNavigationDestination
}

/// An action on a chat that failed outside the open chat's turn, as renaming
/// or deleting a chat in the list, which an alert explains.
struct ChatActionFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// The rows atop the cloud and local chat lists that stand for a new chat.
enum NewChatRow {
    static let cloudId = "new-chat-cloud"
    static let localId = "new-chat-local"

    static func id(local: Bool) -> String { local ? localId : cloudId }
}

/// Graded reasoning effort exposed to the user, in the chat service's
/// vocabulary.
enum ReasoningEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
}

struct MessageEditSession: Identifiable, Equatable {
    let id: UUID
    let chatId: String
    let messageId: String
    let originalContent: String
}

enum MessageEditSessionTransition {
    static func begin(
        id: UUID = UUID(),
        chatId: String?,
        messages: [Message],
        messageIndex: Int,
        canUseActions: Bool,
        isLoading: Bool
    ) -> MessageEditSession? {
        guard canUseActions,
              !isLoading,
              let chatId,
              messages.indices.contains(messageIndex),
              messages[messageIndex].role == .user else {
            return nil
        }
        let message = messages[messageIndex]
        return MessageEditSession(
            id: id,
            chatId: chatId,
            messageId: message.id,
            originalContent: message.content
        )
    }

    static func saveIndex(
        for session: MessageEditSession,
        chatId: String?,
        messages: [Message],
        newContent: String,
        canUseActions: Bool,
        isLoading: Bool
    ) -> Int? {
        guard canUseActions,
              !isLoading,
              session.chatId == chatId,
              !newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let messageIndex = messages.firstIndex(where: { $0.id == session.messageId }),
              messages[messageIndex].role == .user else {
            return nil
        }
        return messageIndex
    }

    static func reconcile(
        _ session: MessageEditSession?,
        chatId: String?,
        messages: [Message]
    ) -> MessageEditSession? {
        guard let session,
              session.chatId == chatId,
              messages.contains(where: { $0.id == session.messageId && $0.role == .user }) else {
            return nil
        }
        return session
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat", category: "Chat")

    // MARK: - Session

    /// The account's use of the chat service, made anew as the account
    /// changes: a signed-out caller has one too.
    @Published var session: ChatSession? {
        didSet { sessionGeneration += 1 }
    }
    private var sessionCancellables: Set<AnyCancellable> = []

    var account: HarnessAccount? { session?.account }

    // MARK: - Open chat

    @Published var activeStorageTab: ChatStorageTab = .cloud
    @Published private(set) var messageEditSession: MessageEditSession?
    private var previousChatIdBeforeTemporary: String?
    @Published private(set) var forkingChatId: String?
    private var previousOpenChatId: String?

    // MARK: - Settings

    @Published var currentModel: ModelType
    @Published var reasoningEffort: ReasoningEffort = .medium {
        didSet { if !isApplyingProfile { saveSetting("reasoningEffort", reasoningEffort.rawValue) } }
    }
    @Published var thinkingEnabled: Bool = true {
        didSet { if !isApplyingProfile { saveSetting("thinkingEnabled", thinkingEnabled) } }
    }
    @Published var autoIntelligence: AutoIntelligence = .default {
        didSet { if !isApplyingProfile { saveSetting("autoIntelligence", autoIntelligence.rawValue) } }
    }
    private var isApplyingProfile = false

    // MARK: - Verification

    struct VerificationInfo {
        var isVerifying: Bool = false
        var isVerified: Bool = false
        var error: String? = nil
    }
    @Published var verification = VerificationInfo()
    @Published var enclaveVerification: Verification? = nil
    private var isRetryingSession = false
    var isVerifying: Bool { verification.isVerifying }
    var isVerified: Bool { verification.isVerified }
    var verificationError: String? { verification.error }

    // MARK: - UI state

    @Published var showVerifierSheet: Bool = false
    @Published var showAddSheet: Bool = false
    @Published var showModelSelectorSheet: Bool = false
    @Published var showDocumentPicker: Bool = false
    @Published var showPhotoPicker: Bool = false
    @Published var showCamera: Bool = false
    @Published var showDocumentScanner: Bool = false
    @Published var showMessageSheet: Bool = false
    @Published var showSidebarSettings: Bool = false
    @Published var showCloudSyncOnboarding: Bool = false
    @Published var cloudSyncOnboardingMode: CloudSyncOnboardingMode = .setup
    @Published var passkeySetupFailure: PasskeyFlowFailure?
    @Published var shouldExpandProjectsInSidebar: Bool = false
    @Published private(set) var navigationRequest: ChatNavigationRequest?
    @Published var isViewingProjectChat: Bool = false
    @Published var shouldFocusInput: Bool = false
    var focusInputAfterDismiss = false
    @Published var isScrollInteractionActive: Bool = false
    @Published var isAtBottom: Bool = true
    @Published var scrollToBottomTrigger: UUID = UUID()
    @Published private(set) var isLoadingEarlierMessages = false
    @Published var scrollToUserMessageTrigger: UUID = UUID()
    @Published var imageViewerImages: [Attachment] = []
    @Published var imageViewerIndex: Int = 0
    @Published var showImageViewer: Bool = false
    @Published var showRateLimitPaywall: Bool = false
    @Published var actionFailure: ChatActionFailure?
    @Published var verifierView: VerifierView?
    @Published var shouldShowKeyImport: Bool = false
    @Published private(set) var isPasskeyRecoverySkipped: Bool = false

    // MARK: - Audio

    let speechPlayer = SpeechPlayer()
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var audioError: String? = nil
    @Published var showMicrophonePermissionAlert: Bool = false
    var audioRecordingStartId: UUID?
    /// The transcription in progress; a newer one, or none, supersedes it.
    var audioTranscriptionId: UUID?

    // MARK: - Attachments

    @Published var pendingAttachments: [Attachment] = []
    @Published var attachmentError: String? = nil
    @Published var pendingImageThumbnails: [String: String] = [:]
    let attachmentProcessingStore = AttachmentProcessingStore()
    var attachmentErrorPublicationFence = AttachmentErrorPublicationFence()
    /// The attachments the chat service converted, by the pending
    /// attachment they stand for, which the next turn sends.
    var uploadedAttachments: [String: Components.Schemas.Attachment] = [:]

    // MARK: - Safeguards

    @Published private(set) var safeguardFlaggedChatIds: Set<String> = []
    @Published private(set) var safeguardsHaveLoaded = false
    private var safeguardsCancellable: AnyCancellable?

    // MARK: - Projects

    @Published var projects: [Project] = []
    @Published var activeProject: Project? {
        didSet { session?.setProject(activeProject?.id) }
    }
    @Published var projectDocuments: [ProjectDocument] = []
    @Published var isLoadingProjects: Bool = false
    @Published var isLoadingProject: Bool = false
    @Published var isUploadingProjectDocument: Bool = false
    @Published var projectError: String?
    var projectListLoadGeneration = 0
    /// A newer project load supersedes one in flight.
    var projectLoadGeneration = 0

    // MARK: - Account

    let passkeyManager = PasskeyManager.shared
    var isAppPresentationReady = false
    var needsSignInWhenPresentationReady = false
    var signInTask: Task<Void, Never>?
    var heldKeyRegistrationTask: Task<Void, Never>?
    var accountOperationFence = AccountOperationFence()
    let accountOperationTracker = AccountOperationTracker()
    var activeSignInToken: AccountOperationFence.Token?
    @Published var isAccountTeardownInProgress = false
    @Published var readyForAccountActionsUserId: String? {
        didSet { if readyForAccountActionsUserId != nil { passkeyManager.resumeAccountOperations() } }
    }
    @Published var rateLimit: RateLimitInfo?

    @Published var authManager: AuthManager? {
        didSet {
            if authManager !== oldValue { speechPlayer.stop() }
            bindSafeguardsStore()
            cancelMessageEdit()
            if currentUserId == nil { clearProjectState() }
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Counts the session's changes, so what the views show is built once
    /// per change rather than on every read.
    private var sessionGeneration = 0
    private var shownChat: (generation: Int, chat: Chat?)?
    private var shownChats: (generation: Int, chats: [Chat])?
    /// The open chat's rows, which keep their ids while a turn replaces its
    /// messages, as the chat table expects.
    private var rows = ChatRows()
    /// A reply streams a token at a time, and each change of the session
    /// redraws every view of the chat. Changes publish on the next turn of the
    /// main actor, and while a reply streams at most every uiUpdateInterval; a
    /// change to what the table lays out publishes at once.
    private var publishEvaluation: Task<Void, Never>?
    private var trailingPublish: Task<Void, Never>?
    private var nextPublishAt = Date.distantPast
    private var publishedLayout: SessionLayout?
    /// The reply whose first text ticks the haptic, and how far it got.
    private var hapticReply: (id: String, ticks: Int, lastAt: Date, length: Int)?
    /// The user stopped the reply, which was announced as stopped rather than
    /// complete.
    private var stopAnnounced = false
    /// A reply asked for again scrolls its message to the top once its turn
    /// starts, when the reply's row has replaced the one it regenerates.
    private var scrollsToTurnOnStart = false
    private lazy var streamingHaptic = UIImpactFeedbackGenerator(style: .light)
    /// Whether the account changed since a session was opened for it.
    private var sessionUserId: String?? = nil

    // MARK: - Init

    init() {
        currentModel = ModelType.auto
        loadDeviceSettings()
        passkeyManager.$recoverySkipped
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPasskeyRecoverySkipped)
        Task { await openSession() }
        observers.append(NotificationCenter.default.addObserver(forName: .cloudSyncSettingChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.storageModeChanged() }
        })
        // A chat service that could not be reached is tried again as the app
        // returns and as the network does.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryClientSetupIfFailed() }
        })
        AppConfig.shared.networkMonitor.$isConnected
            .dropFirst()
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.retryClientSetupIfFailed() }
            .store(in: &cancellables)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func loadDeviceSettings() {
        let defaults = UserDefaults.standard
        if let effort = defaults.string(forKey: Constants.StorageKeys.Settings.reasoningEffort).flatMap(ReasoningEffort.init(rawValue:)) { reasoningEffort = effort }
        if defaults.object(forKey: Constants.StorageKeys.Settings.thinkingEnabled) != nil { thinkingEnabled = defaults.bool(forKey: Constants.StorageKeys.Settings.thinkingEnabled) }
        if let level = defaults.string(forKey: Constants.StorageKeys.Settings.autoIntelligence).flatMap(AutoIntelligence.init(rawValue:)) { autoIntelligence = level }
        if let tab = defaults.string(forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab).flatMap(ChatStorageTab.init(rawValue:)) { activeStorageTab = tab }
    }

    // MARK: - The account's session

    var currentUserId: String? {
        guard authManager?.isAuthenticated == true else { return nil }
        return authManager?.localUserId
    }

    var hasChatAccess: Bool {
        authManager?.isAuthenticated == true
    }

    var hasPremiumAccess: Bool {
        PremiumProjectPolicy.hasAccess(isAuthenticated: authManager?.isAuthenticated == true, hasActiveSubscription: authManager?.hasActiveSubscription == true)
    }

    /// Opens the chat service for the current account, or for a signed-out
    /// caller, replacing the session of the account before.
    func openSession() async {
        let userId = currentUserId
        if case .some(let opened) = sessionUserId, opened == userId, session != nil { return }
        sessionUserId = .some(userId)
        // The chat a signed-out caller had open stays open once it is the
        // account's.
        var keptOpenChatId: String?
        if let previous = session, previous.account.userId == nil, userId != nil {
            memoryChats = await Self.deviceChats(of: previous.device)
            keptOpenChatId = previous.open.id.flatMap { id in memoryChats.contains { $0.thread.id == id } ? id : nil }
        }
        session?.account.dispose()
        sessionCancellables = []
        publishEvaluation?.cancel()
        publishEvaluation = nil
        trailingPublish?.cancel()
        trailingPublish = nil
        publishedLayout = nil
        hapticReply = nil
        scrollsToTurnOnStart = false
        rows = ChatRows()
        session = nil
        verification = VerificationInfo(isVerifying: true)
        // The account's settings load with its key as the session opens,
        // before its sign-in runs.
        if let userId { EncryptionService.shared.bind(userId: userId) }
        let account: HarnessAccount
        do {
            account = try Self.makeAccount(userId: userId, authManager: authManager)
        } catch {
            verification = VerificationInfo(error: error.localizedDescription)
            return
        }
        let directory = userId.flatMap { try? DeviceThreadStore.directory(userId: $0) }
        let store = DeviceThreadStore(directory: directory)
        let session = ChatSession(account: account, device: store, cache: ChatListCache(directory: directory), receipts: RunReceiptStore(userId: userId))
        self.session = session
        ProfileManager.shared.bind(account)
        KeyRegistry.shared.bind(account)
        await LinkMetadataService.shared.bind(account)
        session.objectWillChange.sink { [weak self] _ in self?.sessionChanged() }.store(in: &sessionCancellables)
        account.$rateLimit.receive(on: RunLoop.main).sink { [weak self] limit in self?.rateLimit = limit.flatMap(RateLimitInfo.init) }.store(in: &sessionCancellables)
        account.$profile.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyProfileSettings() }.store(in: &sessionCancellables)
        account.$session.receive(on: RunLoop.main).sink { [weak self, weak account] loaded in
            self?.applySessionModels()
            guard loaded != nil, let account else { return }
            Task { await self?.showVerification(of: account) }
        }.store(in: &sessionCancellables)
        account.$chatRevision.receive(on: RunLoop.main).sink { [weak self] _ in Task { await self?.session?.refreshIfChanged() } }.store(in: &sessionCancellables)
        account.$projectRevision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in Task { await self?.loadProjects() } }.store(in: &sessionCancellables)
        account.$keyReady.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] ready in
            guard ready else { return }
            self?.session?.list.reload()
            Task { await self?.loadProjects() }
        }.store(in: &sessionCancellables)
        await migrateMemoryChats(into: store)
        session.newChat(local: activeStorageTab == .local)
        session.list.reloadDevice()
        // The stored chats listed last time show while the account loads.
        session.list.reload()
        if let keptOpenChatId { selectChat(id: keptOpenChatId, isLocalOnly: true) }
        do {
            try await account.refresh(credentials: true)
            guard self.session === session else { return }
        } catch {
            guard self.session === session else { return }
            verification = VerificationInfo(error: error.localizedDescription)
            account.report(error)
            // The settings this device holds show even while the chat
            // service cannot be reached.
            if !account.cloud { await account.refreshProfile() }
        }
        account.watchChanges()
        Task { await upgradeOlderDeviceChats(session) }
    }

    private static func makeAccount(userId: String?, authManager: AuthManager?) throws -> HarnessAccount {
        let controlPlane = try URLSessionControlPlane()
        // The quota a mint reports goes to the account, which is made after
        // its chat access.
        let quota = MintedQuotaRelay()
        let chatAccess = ChatAccessCache(controlPlane: controlPlane) { limit in
            Task { @MainActor in quota.account?.reportMintedRateLimit(limit) }
        }
        let credentials = HarnessCredentialProvider(
            // Requests go as the account the session was opened for, or not
            // at all: a signed-in account never falls back to a free key.
            identity: { refresh in
                guard let userId else { return nil }
                let token = try await ClerkIdentity.token(refresh: refresh)
                guard await ClerkIdentity.userId() == userId else { throw CancellationError() }
                guard let token else { throw HarnessError.unauthenticated }
                return token
            },
            chatAccess: chatAccess,
            anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
        )
        let transport = try SealedTransport()
        let client = HarnessClient(credentials: credentials, transport: transport)
        let account = HarnessAccount(
            userId: userId,
            client: client,
            credentials: credentials,
            keyBytes: { try? EncryptionService.shared.getKeyBytesOrThrow() },
            settings: DeviceProfileStorage(),
            cloudSync: SettingsManager.shared.isCloudSyncEnabled
        )
        quota.account = account
        return account
    }

    /// The chats a signed-out caller kept in memory follow the account they
    /// sign in to, onto this device.
    private var memoryChats: [DeviceChatCopy] = []

    private static func deviceChats(of store: LocalThreadStore) async -> [DeviceChatCopy] {
        guard let listed = try? await store.list() else { return [] }
        var copies: [DeviceChatCopy] = []
        for summary in listed {
            guard let thread = try? await store.get(summary.id), !thread.messages.isEmpty else { continue }
            let originals = (try? await store.originals(summary.id, attachmentIds: thread.attachments.map(\.id))) ?? [:]
            copies.append(DeviceChatCopy(thread: thread, originals: originals))
        }
        return copies
    }

    private func migrateMemoryChats(into store: LocalThreadStore) async {
        guard currentUserId != nil, !memoryChats.isEmpty else { return }
        for copy in memoryChats {
            do {
                _ = try await store.add(copy.thread, originals: copy.originals)
            } catch {
                Self.logger.error("Failed to keep a signed-out chat for the account: \(error, privacy: .public)")
            }
        }
        memoryChats = []
    }

    /// Chats this device kept in the previous client's format are converted
    /// once by the chat service, as they are listed.
    private func upgradeOlderDeviceChats(_ session: ChatSession) async {
        guard let userId = currentUserId else { return }
        await LegacyDeviceChats.upgrade(userId: userId, account: session.account, into: session.device)
        guard self.session === session else { return }
        session.list.reloadDevice()
    }

    /// Cloud sync was turned on or off in Settings.
    private func storageModeChanged() async {
        guard let session else { return }
        let enabled = SettingsManager.shared.isCloudSyncEnabled
        await session.account.storageModeChanged(cloudSync: enabled)
        if !session.account.cloud {
            session.list.clearCloud()
            if session.open.id == nil {
                session.newChat(local: true)
            } else if !session.open.onDevice {
                session.newChat(local: true)
            }
            activeStorageTab = .local
        } else {
            session.list.reload()
            if session.open.id == nil { session.newChat(local: activeStorageTab == .local) }
        }
    }

    // MARK: - Models and settings from the session

    private func applySessionModels() {
        if let minimum = account?.session?._protocol.minimum { AppConfig.shared.harnessServes(minimumProtocol: minimum) }
        guard let models = account?.session?.models else { return }
        let available = models.map(ModelType.init)
        if session?.open.id == nil, session?.open.modelChosen != true, let shown = openChatModel {
            currentModel = shown
        } else if let current = available.first(where: { $0.id == currentModel.id }) {
            currentModel = current
        } else if let picked = session.flatMap({ session in available.first { $0.id == session.pickedModel } }) {
            currentModel = picked
        } else if let first = available.first {
            currentModel = first
        }
    }

    var availableModels: [ModelType] {
        (account?.session?.models ?? []).filter { !$0.deprecated || $0.id == currentModel.id }.map(ModelType.init)
    }

    /// Models shown in the picker: Auto first, then the real models.
    var selectableModels: [ModelType] {
        let real = availableModels.filter { !$0.isAuto }
        guard let auto = availableModels.first(where: \.isAuto) else { return real }
        return [auto] + real
    }

    /// Resolve a selectable id (Auto, a legacy Auto tier id, or real) back to
    /// a model.
    func findSelectableModel(id: String) -> ModelType? {
        if AutoModel.isAutoId(id) { return selectableModels.first { $0.isAuto } }
        return availableModels.first { $0.id == id }
    }

    private func applyProfileSettings() {
        guard let profile = account?.effectiveProfile else { return }
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        if let effort = profile.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:)), effort != reasoningEffort { reasoningEffort = effort }
        if let thinking = profile.thinkingEnabled, thinking != thinkingEnabled { thinkingEnabled = thinking }
        if let level = profile.autoIntelligence.flatMap(AutoIntelligence.init(rawValue:)), level != autoIntelligence { autoIntelligence = level }
        if session?.open.modelChosen != true, session?.open.id == nil { showOpenChatModel() }
    }

    /// The model the open chat shows: the one it was opened with or the user
    /// picked for it, or for a new chat the one its prompt chooses or the one
    /// new chats follow.
    private var openChatModel: ModelType? {
        guard let session else { return nil }
        let open = session.open
        return findSelectableModel(id: session.presetChoice().model ?? (open.model.isEmpty ? session.pickedModel : open.model))
    }

    /// The model picker shows the open chat's model.
    private func showOpenChatModel() {
        if let model = openChatModel { currentModel = model }
    }

    private func saveSetting(_ field: String, _ value: Any) {
        ProfileManager.shared.save([field: value])
    }

    func changeModel(to model: ModelType) {
        currentModel = model
        session?.setModel(model.id)
        saveSetting("selectedModel", model.id)
        keepWithOpenChat(ThreadPatch(model: model.id))
    }

    /// Whether the open chat searches the web, as its toggle shows it.
    var isWebSearchEnabled: Bool { currentChat?.webSearchEnabled ?? newChatWebSearch }

    /// Whether a new chat searches the web until the user or its prompt
    /// chooses: as the profile says, which the chat service starts new chats
    /// with.
    private var newChatWebSearch: Bool { account?.effectiveProfile.webSearchEnabled ?? true }

    func setWebSearchEnabled(_ enabled: Bool) {
        session?.setWebSearch(enabled)
        keepWithOpenChat(ThreadPatch(webSearchEnabled: enabled))
    }

    /// A setting changed in the open chat is kept with the chat, wherever it
    /// is stored, so it opens with it here and on other devices. A chat not
    /// written yet takes its settings with its first turn.
    private func keepWithOpenChat(_ patch: ThreadPatch) {
        guard let session, let id = session.open.id, session.open.unsaved != id else { return }
        Task {
            do {
                _ = try await session.update(id, patch)
            } catch {
                Self.logger.error("Failed to keep a setting with the open chat: \(error, privacy: .public)")
            }
        }
    }

    var webSearchAvailable: Bool {
        account?.session?.features.additionalProperties["webSearch"] == true
    }

    // MARK: - Safeguards

    private func bindSafeguardsStore() {
        safeguardsCancellable?.cancel()
        safeguardsCancellable = nil
        safeguardFlaggedChatIds = []
        safeguardsHaveLoaded = false
        guard let store = authManager?.safeguards else { return }
        #if DEBUG
        safeguardsCancellable = Publishers.CombineLatest3(store.$flaggedChatIds, store.$simulatedFlaggedChatIds, store.$report)
            .receive(on: RunLoop.main)
            .sink { [weak self] flaggedChatIds, simulatedFlaggedChatIds, report in
                self?.applySafeguardsState(flaggedChatIds: flaggedChatIds.union(simulatedFlaggedChatIds), hasLoaded: report != nil)
            }
        #else
        safeguardsCancellable = Publishers.CombineLatest(store.$flaggedChatIds, store.$report)
            .receive(on: RunLoop.main)
            .sink { [weak self] flaggedChatIds, report in
                self?.applySafeguardsState(flaggedChatIds: flaggedChatIds, hasLoaded: report != nil)
            }
        #endif
    }

    private func applySafeguardsState(flaggedChatIds: Set<String>, hasLoaded: Bool) {
        let newlyFlagged = flaggedChatIds.subtracting(safeguardFlaggedChatIds)
        safeguardFlaggedChatIds = flaggedChatIds
        safeguardsHaveLoaded = hasLoaded
        for chatId in newlyFlagged { enforceSafeguardReadOnlyIfNeeded(chatId: chatId) }
    }

    /// A flagged chat takes no more turns: what is being written or recorded
    /// for it is dropped, and a running reply stopped.
    private func enforceSafeguardReadOnlyIfNeeded(chatId: String) {
        guard authManager?.isAuthenticated == true, safeguardFlaggedChatIds.contains(chatId) else { return }
        if currentChat?.id == chatId {
            cancelMessageEdit()
            cancelAudioRecording()
            clearPendingAttachments()
            if isChatStreaming { cancelGeneration() }
        }
    }

    var isCurrentChatSafeguardFlagged: Bool {
        guard authManager?.isAuthenticated == true, let chatId = currentChat?.id else { return false }
        return safeguardFlaggedChatIds.contains(chatId) || session?.state.flagged == true
    }

    private var isSafeguardGenerationBlocked: Bool {
        guard authManager?.isAuthenticated == true else { return false }
        return !safeguardsHaveLoaded || isCurrentChatSafeguardFlagged
    }

    /// The id of the row an error shows in when no reply answers the last
    /// message, after that message's id.
    private static let errorRowSuffix = "-error"

    // MARK: - Publishing the session

    /// What the chat table lays out: a change to it publishes at once.
    private struct SessionLayout: Equatable {
        let chatId: String?
        let loadingId: String?
        let failedId: String?
        let failed: Bool
        /// A new chat took its id with the turn it is sending.
        let firstTurn: Bool
        /// The chat service titled the chat.
        let titled: Bool
        let status: ChatState.Status
        let messageCount: Int
        let lastMessageId: String?

        @MainActor init(_ session: ChatSession) {
            chatId = session.open.id
            loadingId = session.open.loadingId
            failedId = session.open.failedId
            failed = session.open.failure != nil
            firstTurn = session.isNewChatsFirstTurn
            titled = session.state.snapshot.thread?.titleState == .generated
            status = session.state.status
            messageCount = session.state.messages.count
            lastMessageId = session.state.messages.last?.id
        }
    }

    private func sessionChanged() {
        // What the views show is rebuilt on its next read, while the views
        // redraw when the change publishes.
        sessionGeneration += 1
        guard publishEvaluation == nil else { return }
        publishEvaluation = Task { @MainActor [weak self] in
            self?.publishEvaluation = nil
            self?.publishSessionChange(force: false)
        }
    }

    private func publishSessionChange(force: Bool) {
        let layout = session.map(SessionLayout.init)
        let now = Date()
        if !force, session?.state.status == .streaming, layout == publishedLayout, now < nextPublishAt {
            guard trailingPublish == nil else { return }
            let delay = nextPublishAt.timeIntervalSince(now)
            trailingPublish = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * Double(NSEC_PER_SEC)))
                guard !Task.isCancelled, let self else { return }
                self.trailingPublish = nil
                self.publishSessionChange(force: true)
            }
            return
        }
        trailingPublish?.cancel()
        trailingPublish = nil
        announceGenerationStatus(from: publishedLayout, to: layout)
        if layout?.chatId != publishedLayout?.chatId { scrollsToTurnOnStart = false }
        if scrollsToTurnOnStart, let layout, [.submitting, .queued, .streaming].contains(layout.status) {
            scrollsToTurnOnStart = false
            isScrollInteractionActive = false
            scrollToUserMessageTrigger = UUID()
        }
        publishedLayout = layout
        nextPublishAt = now.addingTimeInterval(Constants.Streaming.uiUpdateInterval)
        tickStreamingHaptic(at: now)
        // Reading aloud stops, and an edit is given up, once its message is
        // no longer shown, as when the chat changes or the message is
        // regenerated or deleted.
        if speechPlayer.snapshot.owner != nil || messageEditSession != nil {
            let chat = currentChat
            speechPlayer.reconcile(chatId: chat?.id, messages: chat?.messages ?? [])
            let edit = MessageEditSessionTransition.reconcile(messageEditSession, chatId: chat?.id, messages: chat?.messages ?? [])
            if edit != messageEditSession { messageEditSession = edit }
        }
        objectWillChange.send()
    }

    /// VoiceOver hears a reply start, finish or fail in the chat on screen,
    /// as the web app's live region announces it, and a haptic marks a reply
    /// finishing or failing and the chat taking its title.
    private func announceGenerationStatus(from previous: SessionLayout?, to next: SessionLayout?) {
        guard let previous, let next, previous.chatId == next.chatId || (previous.chatId == nil && next.firstTurn) else { return }
        if previous.chatId == next.chatId, !previous.titled, next.titled { HapticFeedback.trigger(.success) }
        guard previous.status != next.status else { return }
        let running: Set<ChatState.Status> = [.submitting, .queued, .streaming]
        let wasRunning = running.contains(previous.status), isRunning = running.contains(next.status)
        if !wasRunning, isRunning {
            stopAnnounced = false
            AccessibilityAnnouncer.announce(Constants.Accessibility.generatingResponse)
        } else if wasRunning, next.status == .error || next.failed {
            AccessibilityAnnouncer.announce(Constants.Accessibility.responseFailed)
            HapticFeedback.trigger(.error)
        } else if wasRunning, next.status == .idle {
            if !stopAnnounced {
                AccessibilityAnnouncer.announce(Constants.Accessibility.responseComplete)
                HapticFeedback.trigger(.success)
            }
            stopAnnounced = false
        }
    }

    /// A light haptic ticks as a reply's first text arrives, a few times
    /// spaced out, when haptics are on.
    private func tickStreamingHaptic(at now: Date) {
        guard SettingsManager.shared.hapticFeedbackEnabled, let state = session?.state, state.status == .streaming,
              let reply = state.messages.last, reply.role == .assistant else { return }
        let length = reply.timeline?.reduce(0) { $1._type == .content ? $0 + ($1.content?.utf8.count ?? 0) : $0 } ?? 0
        var tick = hapticReply?.id == reply.id ? hapticReply! : (id: reply.id, ticks: 0, lastAt: .distantPast, length: 0)
        defer { hapticReply = tick }
        guard length > tick.length else { return }
        tick.length = length
        guard tick.ticks < Constants.Streaming.hapticTicks, now.timeIntervalSince(tick.lastAt) >= Constants.Streaming.hapticInterval else { return }
        tick.ticks += 1
        tick.lastAt = now
        streamingHaptic.impactOccurred(intensity: Constants.Streaming.hapticIntensity)
    }

    // MARK: - The open chat as the views show it

    var messages: [Message] {
        currentChat?.messages ?? []
    }

    /// A reply of the open chat is being generated.
    var isLoading: Bool {
        session?.running == true
    }

    /// The open chat starts with older messages than those shown.
    var hasEarlierMessages: Bool {
        guard let session else { return false }
        return session.state.hasOlder && session.open.loadingId == nil
    }

    /// Loads the open chat's messages before those shown.
    func loadEarlierMessages() {
        guard let session, !isLoadingEarlierMessages, hasEarlierMessages else { return }
        isLoadingEarlierMessages = true
        Task {
            defer { isLoadingEarlierMessages = false }
            do {
                try await session.older()
            } catch {
                Self.logger.error("Failed to load earlier messages: \(error, privacy: .public)")
            }
        }
    }

    /// The full image of an attachment of the open chat, which the chat keeps
    /// apart from the thumbnail its message shows.
    func fullImageData(for attachment: Attachment) async -> Data? {
        guard let session else { return nil }
        do {
            return try await session.image(attachment).data
        } catch {
            Self.logger.error("Failed to load an image of the open chat: \(error, privacy: .public)")
            return nil
        }
    }

    /// The harness's id of the message a row of the open chat shows.
    func messageId(ofRow rowId: String) -> String {
        rows.messageId(ofRow: rowId)
    }

    /// The open chat was blank until the turn it is sending gave it its id.
    var isNewChatsFirstTurn: Bool {
        session?.isNewChatsFirstTurn == true
    }

    /// Whether the given chat has a response currently being generated,
    /// regardless of which chat is on screen.
    func isChatStreaming(_ chatId: String) -> Bool {
        guard let session else { return false }
        if session.open.id == chatId { return session.running }
        if session.controller.deviceRuns[chatId] != nil { return true }
        let now = Date()
        return chats.contains { $0.id == chatId && $0.activeRun?.isLive(at: now) == true }
    }

    /// The chat the list shows as open: a new chat outside a project is the
    /// new chat row of the list it will be stored in.
    var selectedChatId: String? {
        guard let session else { return nil }
        if let id = session.open.loadingId ?? session.open.failedId ?? session.open.id { return id }
        guard !session.open.temporary, activeProject == nil else { return nil }
        return NewChatRow.id(local: session.open.local)
    }

    var hydratingChatId: String? { session?.open.loadingId }

    var chatHydrationError: String? {
        guard let session, session.open.failedId != nil else { return nil }
        return session.open.notFound ? "This chat could not be found." : session.open.failure?.message ?? "This chat could not be opened."
    }

    var canRetryFailedChatHydration: Bool { session?.open.failedId != nil }

    func retryFailedChatHydration() {
        guard let session, let failed = session.open.failedId else { return }
        Task { do { _ = try await session.openChat(failed, local: session.open.local) } catch { session.report(error) } }
    }

    var isChatStreaming: Bool { session?.running == true }
    var isOpeningChat: Bool { session?.open.loadingId != nil }
    var hasActiveStreams: Bool { session.map { $0.running || !$0.controller.deviceRuns.isEmpty } == true }
    var canUseCurrentChatActions: Bool { session != nil && !isOpeningChat && session?.open.failedId == nil }

    var canGenerateInCurrentChat: Bool {
        guard let session, canUseCurrentChatActions, !isSafeguardGenerationBlocked else { return false }
        return session.sendBlock == nil
    }

    /// Why the open chat cannot take a turn, which the composer explains.
    var sendBlock: SendBlock? { session?.sendBlock }

    /// The chat service is still opening, or the open chat still waits for
    /// the account's settings or key. A prompt asked for from outside the
    /// app waits for this, as sending does.
    var isConnecting: Bool {
        session == nil || verification.isVerifying || sendBlock == .loading
    }

    var canSendInCurrentContext: Bool {
        guard canGenerateInCurrentChat else { return false }
        if activeProject != nil || currentChat?.projectId != nil { return hasPremiumAccess }
        return true
    }

    var canUseReadAloud: Bool {
        canUseCurrentChatActions && !isCurrentChatSafeguardFlagged && !isRecording && !AudioRecordingService.shared.isRecording
            && account?.session?.features.additionalProperties["speech"] == true && isVerified
    }

    /// The latest summary of the reasoning the reply is thinking through.
    var thinkingSummary: String {
        guard let state = session?.state, state.status == .streaming,
              let last = state.messages.last, last.role == .assistant,
              let block = last.timeline?.last, block._type == .thinking else { return "" }
        return state.summaries[block.id] ?? ""
    }

    var webSearchSummary: String {
        guard let state = session?.state, state.status == .streaming,
              let last = state.messages.last, let block = last.timeline?.last, block._type == .toolCall else { return "" }
        if block.name == "web_search", let query = block.display?.query { return "Searching the web: \(query)" }
        if block.name == "web_fetch", let url = block.display?.url ?? block.display?.sources.first?.url { return "Reading \(url)" }
        return ""
    }

    var queuedMessages: [QueuedMessage] {
        (session?.state.snapshot.queue ?? []).map { item in
            QueuedMessage(id: item.queueId, text: item.content ?? "", attachments: ChatViewMapping.queuedAttachments(item))
        }
    }

    var isMessageQueueFull: Bool {
        queuedMessages.count >= Constants.MessageQueue.maxQueuedMessages
    }

    /// The open chat, built from what its run and store show.
    var currentChat: Chat? {
        if let shownChat, shownChat.generation == sessionGeneration { return shownChat.chat }
        let chat = buildCurrentChat()
        shownChat = (sessionGeneration, chat)
        return chat
    }

    private func buildCurrentChat() -> Chat? {
        guard let session else { return nil }
        let state = session.state
        let open = session.open
        let running = session.running
        let choice = session.presetChoice()
        let model = choice.model ?? (open.model.isEmpty ? session.pickedModel : open.model)
        let replyModelName = findSelectableModel(id: model)?.responseDisplayName
        let messages = rows.rows(chatId: open.id, messages: state.messages, running: running, summaries: state.summaries, replyModelName: replyModelName).map { message -> Message in
            var view = message
            if open.onDevice, !view.attachments.isEmpty {
                // An image the previous client stored without a thumbnail
                // shows its bytes; others load them when opened.
                view.attachments = view.attachments.map { attachment in
                    guard attachment.thumbnailBase64 == nil, let held = session.attachments.images[attachment.id] else { return attachment }
                    var shown = attachment
                    shown.base64 = held.base64
                    return shown
                }
            }
            return view
        }
        let shownMessages = Self.withError(messages, failure: Self.failure(of: session)?.error, replyRowId: rows.awaitedReplyRowId(state.messages))
        let webSearch = open.webSearch ?? choice.webSearchEnabled
        let summary = state.snapshot.thread ?? open.loadingId.flatMap { loading in
            (open.local ? session.list.deviceListed : session.list.cloudListed + session.list.pinnedListed).first { $0.id == loading }
        }
        var chat: Chat
        if let summary {
            chat = ChatViewMapping.chat(summary, messages: shownMessages, local: open.onDevice, temporary: open.temporary, presetId: session.presetId)
            if open.temporary { chat.title = Constants.Harness.temporaryTitle }
            if let webSearch { chat.webSearchEnabled = webSearch }
            chat.pendingSave = open.unsaved == summary.id
        } else {
            let selected = open.loadingId ?? open.failedId ?? open.id
            chat = Chat(id: selected ?? "", title: open.temporary ? Constants.Harness.temporaryTitle : (open.loadingId != nil ? "Loading chat…" : Chat.defaultTitle), messages: shownMessages, createdAt: Date())
            chat.isTemporary = open.temporary
            chat.isLocalOnly = open.onDevice
            chat.pendingSave = open.id != nil && open.unsaved == open.id
            chat.model = model
            chat.projectId = open.onDevice ? nil : open.projectId
            chat.promptPresetId = session.presetId
            chat.webSearchEnabled = webSearch ?? newChatWebSearch
        }
        if state.flagged { chat.flagged = true }
        return chat
    }

    /// The open chat's error, which the card on its last reply explains, and
    /// when its run failed. A request that failed outside a run has no time.
    var shownFailure: (error: HarnessErrorBody, at: Date?)? {
        session.flatMap(Self.failure(of:))
    }

    /// The open chat's error: a request's, its run's, or, for a chat opened
    /// on a reply that did not finish or on a message no reply answers, that
    /// the reply is unfinished.
    private static func failure(of session: ChatSession) -> (error: HarnessErrorBody, at: Date?)? {
        if let failure = session.open.failure { return (failure, nil) }
        if session.state.status == .error, let error = session.state.error { return (error, session.controller.errorAt) }
        return session.hasUnfinishedReply ? (HarnessErrorBody.unfinishedReply, nil) : nil
    }

    /// A run's error shows on the reply it ended, as the message cards show
    /// errors; a turn that ended before its reply started shows it in the row
    /// the reply waited in.
    private static func withError(_ messages: [Message], failure: HarnessErrorBody?, replyRowId: String?) -> [Message] {
        guard let error = failure, !messages.isEmpty else { return messages }
        var shown = messages
        var last = shown[shown.count - 1]
        if last.role == .user {
            // The row keeps its id across rebuilds, so the table does not
            // reload it each time the chat changes.
            var reply = Message(id: replyRowId ?? "\(last.id)\(Self.errorRowSuffix)", role: .assistant, content: "", timestamp: Date())
            reply.modelDisplayName = nil
            shown.append(reply)
            last = shown[shown.count - 1]
        }
        last.streamError = error.message
        last.isRateLimitError = error.code == HarnessErrorCode.quotaExhausted
        last.isHourlyLimitError = error.kind == "hourly"
        shown[shown.count - 1] = last
        return shown
    }

    /// The chats the sidebar lists, the latest active first, under a new chat
    /// row for each list. A run this app streams is active in the list
    /// before the list next reports it.
    var chats: [Chat] {
        if let shownChats, shownChats.generation == sessionGeneration { return shownChats.chats }
        let chats = buildChats()
        shownChats = (sessionGeneration, chats)
        return chats
    }

    private func buildChats() -> [Chat] {
        guard let session else { return [] }
        let listsCloud = session.account.cloud && !session.account.keyLocked
        let openId = session.open.id
        let shownRun = session.running ? session.state.runId : nil
        var listed: [Chat] = []
        if listsCloud {
            let cloud = session.list.cloudListed
            let pins = session.list.pinnedListed.filter { pin in !cloud.contains { $0.id == pin.id } }
            listed += (cloud + pins).map { ChatViewMapping.chat($0, local: false) }
        }
        listed += session.list.deviceListed.map { ChatViewMapping.chat($0, local: true) }
        let shownActivity = session.state.messages.compactMap { ChatAccessCache.date(of: $0.createdAt) }.max()
        let sorted = listed.map { chat in
            var chat = chat
            if chat.activeRun == nil, let runId = session.controller.deviceRuns[chat.id]?.run?.runId ?? (chat.id == openId ? shownRun : nil) {
                chat.activeRun = ActiveRun(runId: runId, expiresAt: "", instance: "")
            }
            if chat.id == openId, let shownActivity, shownActivity > chat.lastActivity { chat.activityAt = shownActivity }
            return chat
        }.sorted { $0.lastActivity > $1.lastActivity }
        guard hasChatAccess else { return sorted }
        let newChats = session.account.cloud ? [Self.newChatRow(local: false), Self.newChatRow(local: true)] : [Self.newChatRow(local: true)]
        return newChats + sorted
    }

    /// The row atop a chat list that starts a new chat stored there.
    private static func newChatRow(local: Bool) -> Chat {
        var chat = Chat(id: NewChatRow.id(local: local), title: Chat.placeholderTitle, createdAt: .distantPast)
        chat.isLocalOnly = local
        return chat
    }

    var cloudSidebarSummaries: [ChatListSummary] {
        chats.filter { !$0.isLocalOnly }.map(ChatListSummary.init)
    }

    var localSidebarSummaries: [ChatListSummary] {
        chats.filter(\.isLocalOnly).map(ChatListSummary.init)
    }

    /// The favorites, the most recently pinned first.
    var favoriteChats: [Chat] {
        guard let session, session.account.cloud, !session.account.keyLocked else { return [] }
        return session.list.pinnedListed.reversed().map { ChatViewMapping.chat($0, local: false) }
    }

    var hasMoreChats: Bool { session?.list.nextCursor != nil }
    var isLoadingMore: Bool { session?.list.loading == true }
    var chatListError: String? { session?.list.error }

    /// Reads again what the chat list failed to read.
    func retryChatList() {
        session?.list.retry()
    }

    func loadMoreChats() async {
        await session?.list.loadMore()?.value
    }

    // MARK: - Navigation

    func requestNavigation(to destination: ChatNavigationDestination) {
        navigationRequest = ChatNavigationRequest(destination: destination)
    }

    func consumeNavigationRequest(id: UUID) {
        if navigationRequest?.id == id { navigationRequest = nil }
    }

    func focusInputIfPending() {
        guard focusInputAfterDismiss else { return }
        focusInputAfterDismiss = false
        shouldFocusInput = true
    }

    func setAppPresentationReady(_ isReady: Bool) {
        isAppPresentationReady = isReady
        guard isReady, needsSignInWhenPresentationReady else { return }
        needsSignInWhenPresentationReady = false
        handleSignIn()
    }

    // MARK: - Chats

    /// Shows the chats of the cloud or of this device, and opens the tab's
    /// most recent chat, or a new chat stored there.
    func switchStorageTab(to tab: ChatStorageTab) {
        guard tab != activeStorageTab, tab == .cloud || SettingsManager.shared.isLocalOnlyModeEnabled else { return }
        activeStorageTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab)
        let local = tab == .local
        let listed = local ? localSidebarSummaries : cloudSidebarSummaries
        if currentChat?.isBlankChat == false, let recent = listed.first(where: { isRootSidebarChat($0) && !$0.isBlankChat }) {
            _ = selectChat(id: recent.id, isLocalOnly: local)
        } else {
            createNewChat(isLocalOnly: local, focusInput: false)
        }
    }

    func createNewRootChat() {
        leaveProjectContext()
        createNewChat()
    }

    /// Starts a new chat where new chats go: on this device without cloud
    /// sync or on the Local tab, in the cloud otherwise, in the open
    /// project if any.
    func createNewChat(modelType: ModelType? = nil, isLocalOnly: Bool? = nil, projectId: String? = nil, focusInput: Bool = true) {
        guard let session else { return }
        cancelMessageEdit()
        cancelAudioRecording()
        let projectId = projectId ?? activeProject?.id
        let local: Bool
        if projectId != nil {
            local = false
        } else if let isLocalOnly {
            local = isLocalOnly
        } else if !SettingsManager.shared.isCloudSyncEnabled {
            local = true
        } else if !SettingsManager.shared.isLocalOnlyModeEnabled {
            local = false
        } else {
            local = activeStorageTab == .local
        }
        openNewChat(local: local)
        session.setProject(projectId)
        if let modelType {
            currentModel = modelType
            session.setModel(modelType.id)
        } else {
            showOpenChatModel()
        }
        if focusInput { shouldFocusInput = true }
        scrollToBottomTrigger = UUID()
    }

    func selectChat(_ chat: Chat) {
        _ = selectChat(id: chat.id, isLocalOnly: chat.isLocalOnly)
    }

    @discardableResult
    func selectChat(id: String, isLocalOnly: Bool) -> Bool {
        guard let session else { return false }
        if id == NewChatRow.id(local: isLocalOnly) {
            guard selectedChatId != id else { return true }
            leaveProjectContext()
            createNewChat(isLocalOnly: isLocalOnly, focusInput: false)
            return true
        }
        if session.open.id == id, session.open.loadingId == nil { return true }
        cancelMessageEdit()
        cancelAudioRecording()
        let originals = pendingOriginals
        Task {
            do {
                _ = try await session.openChat(id, local: isLocalOnly)
                keepPendingOriginals(originals)
                if !session.open.model.isEmpty { showOpenChatModel() }
                scrollToBottomTrigger = UUID()
            } catch {
                keepPendingOriginals(originals)
                session.report(error)
            }
        }
        return true
    }

    /// Opens a new chat in the session. What the composer holds stays for
    /// it: the pending attachments are converted apart from any chat.
    private func openNewChat(local: Bool) {
        guard let session else { return }
        let originals = pendingOriginals
        session.newChat(local: local)
        keepPendingOriginals(originals)
    }

    /// The original images of the pending attachments, which the open chat
    /// holds until a turn sends them, and which opening another chat clears.
    private var pendingOriginals: Originals {
        session?.attachments.originalsOf(Array(uploadedAttachments.values)) ?? [:]
    }

    private func keepPendingOriginals(_ originals: Originals) {
        for (id, original) in originals { session?.attachments.keepOriginal(id, original) }
    }

    /// An action on a chat failed outside the open chat's turn: an alert
    /// explains it, rather than the open chat's last reply.
    func reportActionFailure(_ title: String, _ cause: Error) {
        guard !(cause is CancellationError), let account, !account.disposed else { return }
        if let error = cause as? HarnessError {
            account.reportRateLimit(error.detail.rateLimit)
            HarnessAccount.noteAuthenticationRequired(error)
        }
        actionFailure = ChatActionFailure(title: title, message: cause.localizedDescription)
    }

    func openSummaryChat(id: String, projectId: String?, isLocalOnly: Bool) {
        if let projectId, activeProject?.id != projectId, let project = projects.first(where: { $0.id == projectId }) {
            activeProject = project
        }
        _ = selectChat(id: id, isLocalOnly: isLocalOnly)
    }

    func openSearchResult(_ chat: Chat) {
        openChatInItsContext(id: chat.id, projectId: chat.projectId, isLocalOnly: chat.isLocalOnly)
    }

    /// Opens a chat found outside the open context, as a favorite or a
    /// search result: a project chat opens in its project, so it keeps the
    /// project's documents and instructions, and any other chat leaves the
    /// open project.
    private func openChatInItsContext(id: String, projectId: String?, isLocalOnly: Bool) {
        guard let session, PremiumProjectPolicy.includesChat(projectId: projectId, hasPremiumAccess: hasPremiumAccess) else { return }
        guard let projectId else {
            if activeProject != nil { leaveProjectContext() }
            _ = selectChat(id: id, isLocalOnly: isLocalOnly)
            return
        }
        guard activeProject?.id != projectId else {
            _ = selectChat(id: id, isLocalOnly: false)
            isViewingProjectChat = true
            return
        }
        let shown = (session.opened, session.open.id, session.open.loadingId)
        Task {
            guard await loadActiveProject(projectId: projectId) else {
                if let message = projectError {
                    projectError = nil
                    actionFailure = ChatActionFailure(title: "Couldn't Open Chat", message: message)
                }
                return
            }
            // A chat the user opened while the project loaded stays open.
            guard self.session === session, (session.opened, session.open.id, session.open.loadingId) == shown else { return }
            _ = selectChat(id: id, isLocalOnly: false)
            isViewingProjectChat = true
        }
    }

    /// Deletes a chat. Deleting the open chat opens the chat listed first in
    /// its place; one that fails to delete opens again.
    func deleteChat(_ id: String) {
        guard let session else { return }
        let wasOpen = session.open.id == id
        let local = session.list.isOnDevice(id)
        // The session leaves a deleted open chat for a new one; the user may
        // open another while the deletion is in flight.
        let stillLeft = { session.opened == id && session.open.id == nil && session.open.loadingId == nil }
        Task {
            do {
                try await session.remove(id)
                if wasOpen, stillLeft() { openFirstListedChat(local: local) }
            } catch {
                reportActionFailure("Couldn't Delete Chat", error)
                if wasOpen, stillLeft() { _ = selectChat(id: id, isLocalOnly: local) }
            }
        }
    }

    /// Opens the chat listed first where the open chat was listed: in the
    /// open project, or in the list of the chats stored where it was. A new
    /// chat opens there when none is listed.
    private func openFirstListedChat(local: Bool) {
        let listed = activeProject != nil ? activeProjectChats : (local ? localSidebarSummaries : cloudSidebarSummaries).filter { isRootSidebarChat($0) && !$0.isBlankChat }
        if let first = listed.first {
            _ = selectChat(id: first.id, isLocalOnly: first.isLocalOnly)
        } else {
            createNewChat(isLocalOnly: local, focusInput: false)
        }
    }

    func deleteAllChats() async throws {
        guard let session else { return }
        try await session.removeAll()
        createNewChat(focusInput: false)
    }

    func clearAllChatsFromDevice() async {
        guard let session else { return }
        _ = try? await session.device.deleteAll()
        session.list.reloadDevice()
        if session.open.onDevice { createNewChat(focusInput: false) }
    }

    func updateChatTitle(_ id: String, newTitle: String) async {
        guard let session else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do { _ = try await session.update(id, ThreadPatch(title: title)) } catch { reportActionFailure("Couldn't Rename Chat", error) }
    }

    func canPinChat(_ chat: Chat) -> Bool {
        !chat.isLocalOnly && !chat.isTemporary && !chat.isBlankChat && session?.account.cloud == true
    }

    func canPinChat(_ chat: ChatListSummary) -> Bool {
        !chat.isLocalOnly && !chat.isTemporary && !chat.isBlankChat && session?.account.cloud == true
    }

    func isChatPinned(_ id: String) -> Bool {
        session?.list.pinnedListed.contains { $0.id == id } == true
    }

    func toggleChatPin(_ chat: Chat) {
        toggleChatPin(id: chat.id)
    }

    func toggleChatPin(_ chat: ChatListSummary) {
        toggleChatPin(id: chat.id)
    }

    private func toggleChatPin(id: String) {
        guard let session else { return }
        let pinned = !isChatPinned(id)
        Task { do { _ = try await session.update(id, ThreadPatch(pinned: pinned)) } catch { reportActionFailure("Couldn't Update Favorites", error) } }
    }

    // MARK: - Temporary chats

    /// The open chat is temporary: it lives in memory and is never stored.
    var isTemporaryMode: Bool { session?.open.temporary == true }

    func toggleTemporaryMode() {
        guard let session else { return }
        cancelAudioRecording()
        if isTemporaryMode {
            if let previous = previousChatIdBeforeTemporary {
                previousChatIdBeforeTemporary = nil
                openNewChat(local: activeStorageTab == .local)
                _ = selectChat(id: previous, isLocalOnly: session.list.isOnDevice(previous))
            } else {
                createNewChat()
            }
        } else {
            previousChatIdBeforeTemporary = currentChat?.isBlankChat == false ? session.open.id : nil
            cancelMessageEdit()
            openNewChat(local: true)
            session.setTemporary(true)
            showOpenChatModel()
            shouldFocusInput = true
        }
    }

    // MARK: - Prompts

    /// Chooses the open chat's prompt; the model picker and the web search
    /// toggle show what the prompt chooses.
    func setPromptPreset(_ presetId: String?) {
        guard let session else { return }
        Task {
            do { try await session.selectPreset(presetId) } catch { reportActionFailure("Couldn't Change Prompt", error) }
            showOpenChatModel()
        }
    }

    /// Starts a chat with a preset. The input is focused once the sheet it
    /// was picked in has dismissed, so the keyboard rises in the chat rather
    /// than inside the dismissing sheet.
    func startChat(withPresetId presetId: String) {
        createNewChat(focusInput: false)
        setPromptPreset(presetId)
        focusInputAfterDismiss = true
    }

    // MARK: - Turns

    private var turnOptions: TurnOptions {
        TurnOptions(
            model: currentModel.id,
            autoIntelligence: currentModel.isAuto ? autoIntelligence.rawValue : nil,
            reasoningEffort: reasoningEffort.rawValue,
            timezone: TimeZone.current.identifier,
            thinking: thinkingEnabled,
            webSearch: webSearchAvailable && isWebSearchEnabled,
            piiCheck: account?.effectiveProfile.piiCheckEnabled ?? true,
            genUI: account?.effectiveProfile.genUIEnabled ?? true
        )
    }

    @discardableResult
    func sendMessage(text: String) -> Bool {
        guard let session, canGenerateInCurrentChat else { return false }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !pendingAttachments.isEmpty else { return false }
        guard attachmentsAreReadyToSend(pendingAttachments) else { return false }
        // A message the chat cannot take now stays in the composer.
        guard session.acceptsTurn else { return false }
        if session.running, isMessageQueueFull { return false }
        if let rateLimit, rateLimit.kind == .freeDaily, rateLimit.exhausted, authManager?.hasActiveSubscription != true {
            showRateLimitPaywall = true
            return false
        }
        let sent = pendingAttachments.compactMap { uploadedAttachments[$0.id] }.map(SentAttachment.uploaded)
        let acknowledged = pendingAttachments
        pendingAttachments = []
        pendingImageThumbnails = [:]
        uploadedAttachments = [:]
        attachmentError = nil
        acknowledgeSharedImports(in: acknowledged)
        let fields = TurnFields(kind: .send, content: content, attachments: sent.isEmpty ? nil : sent, options: turnOptions)
        // A message queued behind a reply keeps the keyboard up for the next.
        if !session.running { dismissKeyboard() }
        Task { await session.send(fields) }
        return true
    }

    func cancelGeneration() {
        guard let session else { return }
        stopAnnounced = true
        AccessibilityAnnouncer.announce(Constants.Accessibility.generationStopped)
        Task { do { try await session.cancel() } catch { session.report(error) } }
    }

    /// Generates the chat's last reply again, or answers its last message
    /// when it has no reply.
    func regenerateLastResponse() {
        guard let session, canGenerateInCurrentChat, let index = session.state.messages.indices.last else { return }
        startTurn(scrollingToMessage: true)
        Task { await session.regenerate(at: index, options: turnOptions) }
    }

    /// Continues a reply whose run failed, or that a chat was opened on
    /// unfinished, from what it streamed. Anything else is retried: a reply
    /// whose stream dropped may still be running.
    func continueLastResponse() {
        guard let session, canGenerateInCurrentChat else { return }
        let state = session.state
        let failed = (state.status == .error && state.failedRun != nil) || session.hasUnfinishedReply
        guard failed, let index = state.messages.indices.last, state.messages[index].role == .assistant else {
            retryLastResponse()
            return
        }
        startTurn(scrollingToMessage: false)
        Task { await session.continueReply(at: index, options: turnOptions) }
    }

    /// Tries the failed reply again, or reconnects to a dropped one.
    func retryLastResponse() {
        guard let session, canGenerateInCurrentChat else { return }
        startTurn(scrollingToMessage: true)
        Task { await session.retry(options: turnOptions) }
    }

    /// A turn the user starts puts the keyboard away; one that asks for a
    /// reply again shows its message at the top as the reply comes in.
    private func startTurn(scrollingToMessage: Bool) {
        dismissKeyboard()
        if scrollingToMessage { scrollsToTurnOnStart = true }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func removeQueuedMessage(id: String) {
        guard let session else { return }
        Task { do { try await session.removeQueued(id) } catch { reportActionFailure("Couldn't Remove Message", error) } }
    }

    func sendQueuedMessageNow(id: String) {
        guard let session else { return }
        Task { do { try await session.sendQueued(id) } catch { reportActionFailure("Couldn't Send Message", error) } }
    }

    // MARK: - Message actions

    func canForkMessage(at index: Int) -> Bool {
        guard let session, canUseCurrentChatActions, !session.open.temporary, session.open.id != nil, !session.running else { return false }
        return session.state.messages.indices.contains(index)
    }

    func forkChat(throughMessageIndex index: Int) async {
        guard let session, canForkMessage(at: index), let id = session.open.id else { return }
        forkingChatId = id
        defer { forkingChatId = nil }
        do { _ = try await session.fork(at: index) } catch { session.report(error) }
    }

    func deleteMessage(at index: Int) {
        guard let session, canUseCurrentChatActions, !session.running else { return }
        Task { do { try await session.deleteMessage(at: index) } catch { session.report(error) } }
    }

    func editReply(at index: Int, content: String) {
        guard let session, canUseCurrentChatActions, !session.running else { return }
        Task { do { try await session.editReply(at: index, content: content) } catch { session.report(error) } }
    }

    func beginMessageEdit(at messageIndex: Int) {
        guard let edit = MessageEditSessionTransition.begin(chatId: currentChat?.id, messages: messages, messageIndex: messageIndex, canUseActions: canUseCurrentChatActions, isLoading: isOpeningChat) else { return }
        clearPendingAttachments()
        messageEditSession = edit
    }

    func cancelMessageEdit() {
        messageEditSession = nil
    }

    @discardableResult
    func saveMessageEdit(newContent: String) -> Bool {
        guard let session, let edit = messageEditSession,
              let index = MessageEditSessionTransition.saveIndex(for: edit, chatId: currentChat?.id, messages: messages, newContent: newContent, canUseActions: canUseCurrentChatActions, isLoading: isOpeningChat) else { return false }
        messageEditSession = nil
        let messageId = session.state.messages[index].id
        let content = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        startTurn(scrollingToMessage: false)
        Task {
            if session.running { try? await session.cancel() }
            await session.send(TurnFields(kind: .edit, content: content, messageId: messageId, options: turnOptions))
        }
        return true
    }

    /// Asks the control plane again whether the hourly cap lifted.
    func checkRateLimit() async {
        guard let session else { return }
        do { try await session.account.refresh(credentials: true) } catch { session.account.report(error) }
    }

    /// Asks the chat service for new arguments for a widget call that
    /// could not be rendered.
    func retryGenUIToolCall(toolCallId: String) {
        guard let session, genUIRetryStates[toolCallId] != .generating else { return }
        genUIRetryStates[toolCallId] = .generating
        Task {
            let failure = await session.retryToolCall(toolCallId)
            guard let failure else {
                genUIRetryStates[toolCallId] = nil
                return
            }
            switch failure.code {
            case HarnessErrorCode.threadNotFound, HarnessErrorCode.toolUnavailable, HarnessErrorCode.revisionConflict:
                genUIRetryStates[toolCallId] = .staleOrigin
            default:
                genUIRetryStates[toolCallId] = .requestFailed
            }
        }
    }

    @Published private var genUIRetryStates: [String: GenUIRetryState] = [:]

    func genUIRetryState(toolCallId: String) -> GenUIRetryState? {
        genUIRetryStates[toolCallId]
    }

    // MARK: - Verifier

    func showVerifier() {
        verifierView = VerifierView()
        showVerifierSheet = true
    }

    func dismissVerifier() {
        showVerifierSheet = false
        verifierView = nil
    }

    /// Opens the chat service again: the session and the account's settings,
    /// or the whole session when its client could not be made. The open
    /// chat stays.
    func retryClientSetup() {
        guard !verification.isVerifying, !isRetryingSession else { return }
        guard let session else {
            verification = VerificationInfo(isVerifying: true)
            Task {
                sessionUserId = nil
                await openSession()
            }
            return
        }
        isRetryingSession = true
        Task {
            defer { isRetryingSession = false }
            do {
                try await session.account.refresh(credentials: true)
            } catch {
                guard self.session === session else { return }
                if verification.error != nil { verification = VerificationInfo(error: error.localizedDescription) }
                session.account.report(error)
            }
        }
    }

    /// Tries the chat service again when it could not be verified or the
    /// account's settings could not load.
    private func retryClientSetupIfFailed() {
        guard verification.error != nil || account?.profileFailed == true else { return }
        retryClientSetup()
    }

    /// Shows how the enclave the account's session reached was verified.
    private func showVerification(of account: HarnessAccount) async {
        let verified = await account.client.verification()
        guard self.account === account else { return }
        enclaveVerification = verified
        verification = VerificationInfo(isVerified: verified != nil, error: verified == nil ? "The chat service could not be verified." : nil)
    }
}

extension Notification.Name {
    /// Cloud sync was turned on or off in Settings.
    static let cloudSyncSettingChanged = Notification.Name("tinfoil.cloudSyncSettingChanged")
    /// The chat service refused the account's identity, after it was
    /// refreshed: the user has to sign in again.
    static let chatAuthenticationRequired = Notification.Name("tinfoil.chatAuthenticationRequired")
}

/// Hands the quota a mint reports to the account it is for.
@MainActor
private final class MintedQuotaRelay {
    weak var account: HarnessAccount?
}
