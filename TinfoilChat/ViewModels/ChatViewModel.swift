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
    @Published var session: ChatSession?
    private var sessionCancellables: Set<AnyCancellable> = []

    var account: HarnessAccount? { session?.account }

    // MARK: - Open chat

    @Published var activeStorageTab: ChatStorageTab = .cloud
    @Published private(set) var messageEditSession: MessageEditSession?
    @Published var isTemporaryMode: Bool = false
    private var previousChatIdBeforeTemporary: String?
    @Published private(set) var forkingChatId: String?
    private var previousOpenChatId: String?

    // MARK: - Settings

    @Published var currentModel: ModelType
    @Published var isWebSearchEnabled: Bool = false
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
    var isVerifying: Bool { verification.isVerifying }
    var isVerified: Bool { verification.isVerified }
    var verificationError: String? { verification.error }
    @Published var isClientInitializing: Bool = false

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
    @Published var shouldOpenCloudSync: Bool = false
    @Published var shouldExpandProjectsInSidebar: Bool = false
    @Published private(set) var navigationRequest: ChatNavigationRequest?
    @Published var isViewingProjectChat: Bool = false
    @Published var scrollTargetMessageId: String? = nil
    @Published var scrollTargetOffset: CGFloat = 0
    @Published var shouldFocusInput: Bool = false
    var focusInputAfterDismiss = false
    @Published var isScrollInteractionActive: Bool = false
    @Published var isAtBottom: Bool = true
    @Published var scrollToBottomTrigger: UUID = UUID()
    @Published var scrollToUserMessageTrigger: UUID = UUID()
    @Published var imageViewerImages: [Attachment] = []
    @Published var imageViewerIndex: Int = 0
    @Published var showImageViewer: Bool = false
    @Published var showRateLimitPaywall: Bool = false
    @Published var verifierView: VerifierView?
    @Published var isFirstTimeUser: Bool = false
    @Published var showEncryptionSetup: Bool = false
    @Published var shouldShowKeyImport: Bool = false
    @Published private(set) var isPasskeyRecoverySkipped: Bool = false

    // MARK: - Sync and errors

    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var syncErrors: [String] = []

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
    var legacyMigrationTask: Task<Void, Never>?
    var accountOperationFence = AccountOperationFence()
    let accountOperationTracker = AccountOperationTracker()
    var activeSignInToken: AccountOperationFence.Token?
    @Published var isAccountTeardownInProgress = false
    @Published var readyForAccountActionsUserId: String? {
        didSet { if readyForAccountActionsUserId != nil { passkeyManager.resumeAccountOperations() } }
    }
    @Published var rateLimit: RateLimitInfo? {
        didSet {
            guard let rateLimit, authManager?.hasActiveSubscription != true else { return }
            if rateLimit.remaining <= 0, rateLimit.kind == .freeDaily { showRateLimitPaywall = true }
        }
    }

    @Published var authManager: AuthManager? {
        didSet {
            if authManager !== oldValue { speechPlayer.stop() }
            bindSafeguardsStore()
            cancelMessageEdit()
            if authManager?.isAuthenticated == true, let userId = currentUserId {
                lastSyncDate = UserDefaults.standard.object(forKey: Constants.StorageKeys.Sync.lastSyncDate(userId: userId)) as? Date
            } else {
                lastSyncDate = nil
                clearProjectState()
            }
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Whether the account changed since a session was opened for it.
    private var sessionUserId: String?? = nil

    // MARK: - Init

    init() {
        currentModel = ModelType.auto
        loadDeviceSettings()
        Task { await openSession() }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.handleDidBecomeActive() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .cloudSyncSettingChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.storageModeChanged() }
        })
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
        session?.account.dispose()
        sessionCancellables = []
        session = nil
        verification = VerificationInfo(isVerifying: true)
        isClientInitializing = true
        let account: HarnessAccount
        do {
            account = try Self.makeAccount(userId: userId, authManager: authManager)
        } catch {
            verification = VerificationInfo(error: error.localizedDescription)
            isClientInitializing = false
            return
        }
        let directory = userId.flatMap { try? DeviceThreadStore.directory(userId: $0) }
        let store = DeviceThreadStore(directory: directory)
        let session = ChatSession(account: account, device: store, cache: ChatListCache(directory: directory), receipts: RunReceiptStore(userId: userId))
        self.session = session
        ProfileManager.shared.bind(account)
        await LinkMetadataService.shared.bind(account)
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &sessionCancellables)
        account.$rateLimit.receive(on: RunLoop.main).sink { [weak self] limit in self?.rateLimit = limit.flatMap(RateLimitInfo.init) }.store(in: &sessionCancellables)
        account.$profile.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyProfileSettings() }.store(in: &sessionCancellables)
        account.$session.receive(on: RunLoop.main).sink { [weak self] _ in self?.applySessionModels() }.store(in: &sessionCancellables)
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
        do {
            try await account.refresh(credentials: true)
            guard self.session === session else { return }
            let verified = await account.client.verification()
            enclaveVerification = verified
            verification = VerificationInfo(isVerified: verified != nil, error: verified == nil ? "The chat service could not be verified." : nil)
        } catch {
            guard self.session === session else { return }
            verification = VerificationInfo(error: error.localizedDescription)
            account.report(error)
        }
        isClientInitializing = false
        account.watchChanges()
        Task { await upgradeOlderDeviceChats(session) }
    }

    private static func makeAccount(userId: String?, authManager: AuthManager?) throws -> HarnessAccount {
        let controlPlane = try URLSessionControlPlane()
        let chatAccess = ChatAccessCache(controlPlane: controlPlane) { _ in }
        let credentials = HarnessCredentialProvider(
            identity: { refresh in
                guard userId != nil else { return nil }
                return try await ClerkIdentity.token(refresh: refresh)
            },
            chatAccess: chatAccess,
            anonymousAccess: AnonymousAccessCache(controlPlane: controlPlane)
        )
        let transport = try SealedTransport()
        let client = HarnessClient(credentials: credentials, transport: transport)
        return HarnessAccount(
            userId: userId,
            client: client,
            credentials: credentials,
            keyBytes: { try? EncryptionService.shared.getKeyBytesOrThrow() },
            settings: DeviceProfileStorage(),
            cloudSync: SettingsManager.shared.isCloudSyncEnabled
        )
    }

    /// The chats a signed-out caller kept in memory follow the account they
    /// sign in to, onto this device.
    private var memoryChats: [DeviceChatCopy] = []

    private func migrateMemoryChats(into store: LocalThreadStore) async {
        guard currentUserId != nil, !memoryChats.isEmpty else { return }
        for copy in memoryChats {
            _ = try? await store.add(copy.thread, originals: copy.originals)
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

    private func handleDidBecomeActive() async {
        await account?.checkChanges()
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
        guard let models = account?.session?.models else { return }
        let available = models.map(ModelType.init)
        if let current = available.first(where: { $0.id == currentModel.id }) {
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
        if let models = account?.session?.models, let selected = profile.selectedModel, let model = models.first(where: { $0.id == selected }), session?.open.modelChosen != true, session?.open.id == nil {
            currentModel = ModelType(model)
        }
    }

    private func saveSetting(_ field: String, _ value: Any) {
        guard let account else { return }
        Task {
            do { try await account.updateProfile([field: value]) } catch { account.report(error) }
        }
    }

    func changeModel(to model: ModelType) {
        currentModel = model
        session?.setModel(model.id)
        saveSetting("selectedModel", model.id)
    }

    func setWebSearchEnabled(_ enabled: Bool) {
        isWebSearchEnabled = enabled
        session?.setWebSearch(enabled)
        if let id = session?.open.id, session?.open.onDevice == false {
            Task { try? await session?.update(id, ThreadPatch(webSearchEnabled: enabled)) }
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

    // MARK: - The open chat as the views show it

    var messages: [Message] {
        currentChat?.messages ?? []
    }

    /// A reply of the open chat is being generated.
    var isLoading: Bool {
        session?.running == true
    }

    /// Whether the given chat has a response currently being generated,
    /// regardless of which chat is on screen.
    func isChatStreaming(_ chatId: String) -> Bool {
        guard let session else { return false }
        if session.open.id == chatId { return session.running }
        return session.controller.deviceRuns[chatId] != nil
    }

    var selectedChatId: String? {
        guard let session else { return nil }
        return session.open.loadingId ?? session.open.failedId ?? session.open.id
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
        return session.account.profileReady && (session.open.onDevice || session.account.keyReady)
    }

    var canSendInCurrentContext: Bool {
        guard canGenerateInCurrentChat else { return false }
        if activeProject != nil || currentChat?.projectId != nil { return hasPremiumAccess }
        return true
    }

    var canUseReadAloud: Bool {
        canUseCurrentChatActions && !isCurrentChatSafeguardFlagged && !isRecording && !AudioRecordingService.shared.isRecording
            && account?.session?.features.additionalProperties["speech"] != false && isVerified
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
        guard let session else { return nil }
        let state = session.state
        let open = session.open
        let running = session.running
        let messages = state.messages.enumerated().map { index, message -> Message in
            var view = ChatViewMapping.message(message, streaming: running && index == state.messages.count - 1, summaries: state.summaries)
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
        let shownMessages = Self.withError(messages, state: state, failure: open.failure)
        let choice = session.presetChoice()
        let model = choice.model ?? (open.model.isEmpty ? session.pickedModel : open.model)
        let webSearch = open.webSearch ?? choice.webSearchEnabled
        let summary = state.snapshot.thread ?? open.loadingId.flatMap { loading in
            (open.local ? session.list.deviceListed : session.list.cloudListed + session.list.pinnedListed).first { $0.id == loading }
        }
        var chat: Chat
        if let summary {
            chat = ChatViewMapping.chat(summary, messages: shownMessages, local: open.local && !open.temporary, temporary: open.temporary, presetId: session.presetId)
            if open.temporary { chat.title = Constants.Harness.temporaryTitle }
            if let webSearch { chat.webSearchEnabled = webSearch }
            chat.pendingSave = open.unsaved == summary.id
        } else {
            let selected = open.loadingId ?? open.failedId ?? open.id
            chat = Chat(id: selected ?? "", title: open.temporary ? Constants.Harness.temporaryTitle : (open.loadingId != nil ? "Loading chat…" : Chat.defaultTitle), messages: shownMessages, createdAt: Date())
            chat.isTemporary = open.temporary
            chat.isLocalOnly = open.local && !open.temporary
            chat.pendingSave = open.id != nil && open.unsaved == open.id
            chat.model = model
            chat.projectId = open.onDevice ? nil : open.projectId
            chat.promptPresetId = session.presetId
            if let webSearch { chat.webSearchEnabled = webSearch }
        }
        if state.flagged { chat.flagged = true }
        return chat
    }

    /// A run's error shows on the reply it ended, as the message cards show
    /// errors.
    private static func withError(_ messages: [Message], state: ChatState, failure: HarnessErrorBody?) -> [Message] {
        guard let error = failure ?? (state.status == .error ? state.error : nil), !messages.isEmpty else { return messages }
        var shown = messages
        var last = shown[shown.count - 1]
        if last.role == .user {
            var reply = Message(role: .assistant, content: "", timestamp: Date())
            reply.modelDisplayName = nil
            shown.append(reply)
            last = shown[shown.count - 1]
        }
        last.streamError = error.message
        last.isRequestError = true
        last.isRateLimitError = error.code == HarnessErrorCode.quotaExhausted || error.code == HarnessErrorCode.rateLimited
        last.isHourlyLimitError = error.kind == "hourly"
        last.isConnectionError = error.code == HarnessErrorCode.streamInterrupted || error.code == HarnessErrorCode.connection
        shown[shown.count - 1] = last
        return shown
    }

    /// The chats the sidebar lists, the latest active first. A run this app
    /// streams is active in the list before the list next reports it.
    var chats: [Chat] {
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
        return listed.map { chat in
            var chat = chat
            if chat.activeRun == nil, let runId = session.controller.deviceRuns[chat.id]?.run?.runId ?? (chat.id == openId ? shownRun : nil) {
                chat.activeRun = ActiveRun(runId: runId, expiresAt: "", instance: "")
            }
            if chat.id == openId, let shownActivity, shownActivity > chat.lastActivity { chat.activityAt = shownActivity }
            return chat
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    var localChats: [Chat] { chats.filter(\.isLocalOnly) }

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

    func loadMoreChats() async {
        guard let session, let cursor = session.list.nextCursor else { return }
        try? await session.list.refresh(after: cursor)
    }

    func performFullSync() async {
        guard let session else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await session.account.refresh()
            try await session.list.refresh()
            session.list.reloadDevice()
            await loadProjects()
            lastSyncDate = Date()
            if let userId = currentUserId { UserDefaults.standard.set(lastSyncDate, forKey: Constants.StorageKeys.Sync.lastSyncDate(userId: userId)) }
        } catch {
            syncErrors.append(error.localizedDescription)
        }
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

    func switchStorageTab(to tab: ChatStorageTab) {
        guard tab == .cloud || SettingsManager.shared.isLocalOnlyModeEnabled else { return }
        activeStorageTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab)
        if let session, session.open.id == nil || currentChat?.isBlankChat == true {
            session.newChat(local: tab == .local)
        }
    }

    func createNewRootChat() {
        exitProject()
        createNewChat()
    }

    /// Starts a new chat where new chats go: on this device without cloud
    /// sync or on the Local tab, in the cloud otherwise, in the open
    /// project if any.
    func createNewChat(modelType: ModelType? = nil, isLocalOnly: Bool? = nil, projectId: String? = nil, focusInput: Bool = true) {
        guard let session else { return }
        cancelMessageEdit()
        clearPendingAttachments()
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
        isTemporaryMode = false
        session.newChat(local: local)
        session.setProject(projectId)
        if let modelType { currentModel = modelType }
        session.setModel(currentModel.id)
        if focusInput { shouldFocusInput = true }
        scrollToBottomTrigger = UUID()
    }

    func selectChat(_ chat: Chat) {
        _ = selectChat(id: chat.id, isLocalOnly: chat.isLocalOnly)
    }

    @discardableResult
    func selectChat(id: String, isLocalOnly: Bool) -> Bool {
        guard let session else { return false }
        if session.open.id == id, session.open.loadingId == nil { return true }
        cancelMessageEdit()
        clearPendingAttachments()
        isTemporaryMode = false
        Task {
            do {
                _ = try await session.openChat(id, local: isLocalOnly)
                if let model = session.open.model.isEmpty ? nil : session.open.model, let listed = availableModels.first(where: { $0.id == model }) {
                    currentModel = listed
                }
                isWebSearchEnabled = currentChat?.webSearchEnabled ?? isWebSearchEnabled
                scrollToBottomTrigger = UUID()
            } catch {
                session.report(error)
            }
        }
        return true
    }

    func openSummaryChat(id: String, projectId: String?, isLocalOnly: Bool) {
        if let projectId, activeProject?.id != projectId, let project = projects.first(where: { $0.id == projectId }) {
            activeProject = project
        }
        _ = selectChat(id: id, isLocalOnly: isLocalOnly)
    }

    func openSearchResult(_ chat: Chat) {
        exitProject()
        _ = selectChat(id: chat.id, isLocalOnly: chat.isLocalOnly)
    }

    func deleteChat(_ id: String) {
        guard let session else { return }
        Task {
            do {
                try await session.remove(id)
                if session.open.id == nil { createNewChat(focusInput: false) }
            } catch {
                session.report(error)
            }
        }
    }

    func deleteAllChats() async throws {
        guard let session else { return }
        try await session.removeAll()
        createNewChat(focusInput: false)
    }

    func deleteNonLocalChats() async {
        guard let session, session.account.cloud else { return }
        do {
            let _: RawJSON = try await session.account.post(.deleteAll)
            session.list.clearCloud(confirmedEmpty: true)
            if session.open.onDevice == false { createNewChat(focusInput: false) }
        } catch {
            session.report(error)
        }
    }

    func clearAllChatsFromDevice(userId: String? = nil) async {
        guard let session else { return }
        _ = try? await session.device.deleteAll()
        session.list.reloadDevice()
        if session.open.onDevice { createNewChat(focusInput: false) }
    }

    func updateChatTitle(_ id: String, newTitle: String) async {
        guard let session else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do { _ = try await session.update(id, ThreadPatch(title: title)) } catch { session.report(error) }
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
        Task { do { _ = try await session.update(id, ThreadPatch(pinned: pinned)) } catch { session.report(error) } }
    }

    // MARK: - Temporary chats

    func toggleTemporaryMode() {
        guard let session else { return }
        if isTemporaryMode {
            isTemporaryMode = false
            session.newChat(local: activeStorageTab == .local)
            if let previous = previousChatIdBeforeTemporary {
                previousChatIdBeforeTemporary = nil
                _ = selectChat(id: previous, isLocalOnly: session.list.isOnDevice(previous))
            }
        } else {
            previousChatIdBeforeTemporary = currentChat?.isBlankChat == false ? session.open.id : nil
            cancelMessageEdit()
            clearPendingAttachments()
            session.newChat(local: true)
            session.setTemporary(true)
            isTemporaryMode = true
            shouldFocusInput = true
        }
    }

    // MARK: - Prompts

    func setPromptPreset(_ presetId: String?) {
        guard let session else { return }
        Task { do { try await session.selectPreset(presetId) } catch { session.report(error) } }
    }

    func startChat(withPresetId presetId: String) {
        createNewChat()
        setPromptPreset(presetId)
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
            genUI: account?.effectiveProfile.genUIEnabled ?? true,
            cacheSecret: PromptCacheSecret.secret(userId: currentUserId)
        )
    }

    @discardableResult
    func sendMessage(text: String) -> Bool {
        guard let session, canGenerateInCurrentChat else { return false }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !pendingAttachments.isEmpty else { return false }
        guard attachmentsAreReadyToSend(pendingAttachments) else { return false }
        if session.running, isMessageQueueFull { return false }
        if let rateLimit, rateLimit.kind == .freeDaily, rateLimit.remaining <= 0, authManager?.hasActiveSubscription != true {
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
        scrollToBottomTrigger = UUID()
        Task { await session.send(fields) }
        return true
    }

    func cancelGeneration() {
        guard let session else { return }
        Task { do { try await session.cancel() } catch { session.report(error) } }
    }

    func regenerateLastResponse() {
        guard let session, canGenerateInCurrentChat else { return }
        let messages = session.state.messages
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) ?? messages.indices.last else { return }
        Task { await session.regenerate(at: index, options: turnOptions) }
    }

    func continueLastResponse() {
        guard let session, canGenerateInCurrentChat else { return }
        let messages = session.state.messages
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        Task { await session.continueReply(at: index, options: turnOptions) }
    }

    /// Tries the failed reply again, or reconnects to a dropped one.
    func retryLastResponse() {
        guard let session else { return }
        Task { await session.retry(options: turnOptions) }
    }

    func removeQueuedMessage(id: String) {
        guard let session else { return }
        Task { do { try await session.removeQueued(id) } catch { session.report(error) } }
    }

    func sendQueuedMessageNow(id: String) {
        guard let session else { return }
        Task { do { try await session.sendQueued(id) } catch { session.report(error) } }
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
        Task {
            if session.running { try? await session.cancel() }
            await session.send(TurnFields(kind: .edit, content: content, messageId: messageId, options: turnOptions))
        }
        return true
    }

    /// A widget's answer is sent as the user's next message.
    func resolveGenUIToolCall(toolCallId: String, resultText: String, resultData: JSONValue?) {
        _ = sendMessage(text: resultText)
    }

    /// Asks the control plane again whether the hourly cap lifted.
    func checkRateLimit() async {
        guard let session else { return }
        do { try await session.account.refresh(credentials: true) } catch { session.account.report(error) }
    }

    /// Asks the chat service for new arguments for a widget call that
    /// could not be rendered.
    func retryGenUIToolCall(messageId: String, toolCallId: String) {
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

    func genUIRetryState(messageId: String, toolCallId: String) -> GenUIRetryState? {
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

    func retryClientSetup() {
        Task {
            sessionUserId = nil
            await openSession()
        }
    }
}

extension Notification.Name {
    /// Cloud sync was turned on or off in Settings.
    static let cloudSyncSettingChanged = Notification.Name("tinfoil.cloudSyncSettingChanged")
}
