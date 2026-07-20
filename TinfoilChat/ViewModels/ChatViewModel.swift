//
//  ChatViewModel.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import Combine
import SwiftUI
@preconcurrency import TinfoilAI
import OpenAI
import AVFoundation

enum ChatStorageTab: String {
    case cloud
    case local
}

/// Graded reasoning effort exposed to the user. Maps directly onto the
/// webapp vocabulary; per-model translation (e.g. DeepSeek's `low|medium →
/// high`, `high → max`) is handled by `ChatQueryBuilder` via `effortMap`.
enum ReasoningEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
}

struct ChatStreamState {
    private(set) var activeChatIds: Set<String> = []
    private(set) var thinkingSummaries: [String: String] = [:]
    private(set) var webSearchSummaries: [String: String] = [:]

    mutating func start(chatId: String) {
        activeChatIds.insert(chatId)
    }

    mutating func setThinkingSummary(_ summary: String?, chatId: String) {
        thinkingSummaries[chatId] = summary
    }

    mutating func setWebSearchSummary(_ summary: String?, chatId: String) {
        webSearchSummaries[chatId] = summary
    }

    mutating func finish(chatId: String) {
        activeChatIds.remove(chatId)
        thinkingSummaries[chatId] = nil
        webSearchSummaries[chatId] = nil
    }

    func isStreaming(chatId: String) -> Bool {
        activeChatIds.contains(chatId)
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    // Published properties for UI updates
    @Published var chats: [Chat] = []
    @Published var localChats: [Chat] = []
    @Published var currentChat: Chat? {
        didSet {
            let enabled = currentChat?.webSearchEnabled
                ?? SettingsManager.shared.webSearchAvailable
            if isWebSearchEnabled != enabled {
                isWebSearchEnabled = enabled
            }
        }
    }
    @Published var activeStorageTab: ChatStorageTab = .cloud
    @Published private var streamState = ChatStreamState()
    @Published var showVerifierSheet: Bool = false
    @Published var showAddSheet: Bool = false
    @Published var showModelSelectorSheet: Bool = false
    @Published var showDocumentPicker: Bool = false
    @Published var showPhotoPicker: Bool = false
    @Published var showCamera: Bool = false
    @Published var showMessageSheet: Bool = false
    @Published var showSidebarSettings: Bool = false
    @Published var showCloudSyncOnboarding: Bool = false
    @Published var cloudSyncOnboardingMode: CloudSyncOnboardingMode = .setup
    @Published var shouldOpenCloudSync: Bool = false
    @Published var shouldExpandProjectsInSidebar: Bool = false
    @Published var isViewingProjectChat: Bool = false
    @Published var scrollTargetMessageId: String? = nil 
    @Published var scrollTargetOffset: CGFloat = 0 
    /// When set to true, the input field should become first responder (focus keyboard)
    @Published var shouldFocusInput: Bool = false
    // Set when a flow wants the input focused only after a presenting sheet has
    // finished dismissing, so the keyboard rises in the chat's layout.
    var focusInputAfterDismiss = false
    @Published var isScrollInteractionActive: Bool = false
    @Published var isAtBottom: Bool = true
    @Published var scrollToBottomTrigger: UUID = UUID()
    @Published var scrollToUserMessageTrigger: UUID = UUID()
    @Published var isClientInitializing: Bool = false
    @Published var isWebSearchEnabled: Bool = false
    @Published var reasoningEffort: ReasoningEffort = .medium {
        didSet {
            UserDefaults.standard.set(
                reasoningEffort.rawValue,
                forKey: Constants.StorageKeys.Settings.reasoningEffort
            )
            if !isLoadingPersistedSettings {
                ProfileManager.shared.sharedSettingsDidChange()
            }
        }
    }
    @Published var thinkingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                thinkingEnabled,
                forKey: Constants.StorageKeys.Settings.thinkingEnabled
            )
            if !isLoadingPersistedSettings {
                ProfileManager.shared.sharedSettingsDidChange()
            }
        }
    }

    // While true, persisted-setting didSet observers skip the shared-settings
    // sync callback. Loading stored values during init is not a user edit, and
    // touching ProfileManager here would lazily initialize it (and publish its
    // applied profile) in the middle of the SwiftUI update that creates this
    // view model.
    private var isLoadingPersistedSettings = false
    @Published var imageViewerImages: [Attachment] = []
    @Published var imageViewerIndex: Int = 0
    @Published var showImageViewer: Bool = false
    @Published var editRequestedForMessageIndex: Int? = nil

    // Verification properties - consolidated to reduce update frequency
    struct VerificationInfo {
        var isVerifying: Bool = false
        var isVerified: Bool = false
        var error: String? = nil
    }
    @Published var verification = VerificationInfo()
    @Published var verificationDocument: VerificationDocument? = nil
    
    // Cloud sync properties
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date? {
        didSet {
            // Persist to UserDefaults whenever it changes (scoped to user)
            if let date = lastSyncDate, let userId = currentUserId {
                UserDefaults.standard.set(date, forKey: Constants.StorageKeys.Sync.lastSyncDate(userId: userId))
            } else if let userId = currentUserId {
                UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Sync.lastSyncDate(userId: userId))
            }
        }
    }
    @Published var syncErrors: [String] = []
    private var encryptionKey: String?  // Keep private for security
    @Published var isFirstTimeUser: Bool = false
    @Published var showEncryptionSetup: Bool = false
    @Published var shouldShowKeyImport: Bool = false
    @Published private(set) var isPasskeyRecoverySkipped: Bool = false
    private let passkeyManager = PasskeyManager.shared
    private let cloudSync = CloudSyncService.shared
    private let streamingTracker = StreamingTracker.shared
    private let projectStorage = ProjectStorageService.shared
    private var isSignInInProgress: Bool = false  // Prevent duplicate sign-in flows
    private var hasPerformedInitialSync: Bool = false  // Track if initial sync has been done
    private var hasAnonymousChatsToSync: Bool = false  // Track if we have anonymous chats to sync
    
    // Pagination properties
    @Published var isLoadingMore: Bool = false
    @Published var hasMoreChats: Bool = false {
        didSet { persistPaginationStateIfPossible() }
    }
    private var paginationToken: String? = nil {
        didSet { persistPaginationStateIfPossible() }
    }
    private var isPaginationActive: Bool = false  // Track if we're using pagination vs full load
    {
        didSet { persistPaginationStateIfPossible() }
    }
    private var hasLoadedInitialPage: Bool = false  // Track if we've loaded the first page
    {
        didSet { persistPaginationStateIfPossible() }
    }
    private var hasAttemptedLoadMore: Bool = false  // Track if we've tried to load more at least once
    {
        didSet { persistPaginationStateIfPossible() }
    }
    
    // Controls when pagination state is written to storage to avoid clobbering persisted values during init
    private var shouldPersistPaginationState: Bool = false
    {
        didSet { persistPaginationStateIfPossible() }
    }
    
    // IMPORTANT: Pagination token edge cases to handle:
    // 1. Token should NOT be reset during auto-sync operations
    // 2. Token should be preserved when creating/deleting chats locally
    // 3. Token should only be reset when explicitly loading initial page
    // 4. New chats created locally appear at top regardless of pagination state
    // 5. Deleted chats are removed from view but don't affect pagination token
    // 6. First page is loaded during initial sync, pagination starts from page 2
    
    // Computed properties for backward compatibility
    var isVerifying: Bool { verification.isVerifying }
    var isVerified: Bool { verification.isVerified }
    var verificationError: String? { verification.error }
    
    // Rate limit properties
    @Published var rateLimit: RateLimitInfo?
    @Published var showRateLimitPaywall: Bool = false

    // Model properties
    @Published var currentModel: ModelType

    // View state for verifier
    @Published var verifierView: VerifierView?

    // Audio recording properties
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var audioError: String? = nil
    @Published var showMicrophonePermissionAlert: Bool = false

    // Temporary (incognito) chat mode. When active, the current chat is an
    // ephemeral in-memory chat that is never persisted or synced.
    @Published var isTemporaryMode: Bool = false
    private var previousChatIdBeforeTemporary: String?

    // Attachment properties
    @Published var pendingAttachments: [Attachment] = []
    @Published var attachmentError: String? = nil
    @Published var pendingImageThumbnails: [String: String] = [:]
    var isProcessingAttachment: Bool {
        pendingAttachments.contains { $0.processingState == .processing }
    }

    // Project properties
    @Published var projects: [Project] = []
    @Published var activeProject: Project?
    @Published var projectDocuments: [ProjectDocument] = []
    @Published var isLoadingProjects: Bool = false
    @Published var isLoadingProject: Bool = false
    @Published var isUploadingProjectDocument: Bool = false
    @Published var projectError: String?

    // Private properties
    private var client: TinfoilAI?
    private var streamTasks: [String: Task<Void, Never>] = [:]
    private var thinkingSummaryServices: [String: ThinkingSummaryService] = [:]
    private var autoSyncTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
    private var sharedSettingsObserver: NSObjectProtocol?
    private var networkStatusCancellable: AnyCancellable?
    private var streamUpdateTimers: [String: Timer] = [:]
    private var pendingStreamUpdates: [String: Chat] = [:]
    private var pendingSaveTask: Task<Void, Never>?
    private var lastKnownAuthState: Bool?
    
    // Auth reference for Premium features
    @Published var authManager: AuthManager? {
        didSet {
            // Load user-specific last sync date when auth changes
            if let userId = currentUserId {
                lastSyncDate = UserDefaults.standard.object(forKey: Constants.StorageKeys.Sync.lastSyncDate(userId: userId)) as? Date
            } else {
                lastSyncDate = nil
            }
            
            // When auth becomes available and authenticated, restore persisted pagination state immediately
            if authManager?.isAuthenticated == true {
                loadPersistedPaginationState()

                // Move the initial blank chat to the correct array based on cloud sync state.
                // init() always takes the unauthenticated branch (authManager is nil at init time),
                // so the blank chat ends up in `chats`. When cloud sync is off, the sidebar shows
                // `localChats` which is empty. Fix this by moving the chat now.
                if !SettingsManager.shared.isCloudSyncEnabled,
                   let chat = currentChat, chat.isBlankChat, !chat.isLocalOnly {
                    chats.removeAll { $0.id == chat.id }
                    var localChat = chat
                    localChat.isLocalOnly = true
                    localChats = [localChat]
                    currentChat = localChat
                    activeStorageTab = .local
                }
            } else {
                projects = []
                activeProject = nil
                projectDocuments = []
                projectError = nil
            }
        }
    }
    
    var messages: [Message] {
        currentChat?.messages ?? []
    }

    var isLoading: Bool {
        guard let chatId = currentChat?.id else { return false }
        return streamState.isStreaming(chatId: chatId)
    }

    var thinkingSummary: String {
        guard let chatId = currentChat?.id else { return "" }
        return streamState.thinkingSummaries[chatId] ?? ""
    }

    var webSearchSummary: String {
        guard let chatId = currentChat?.id else { return "" }
        return streamState.webSearchSummaries[chatId] ?? ""
    }

    var isProjectMode: Bool {
        activeProject != nil
    }

    var activeProjectChats: [Chat] {
        guard let projectId = activeProject?.id else { return [] }
        return chats
            .filter { $0.projectId == projectId && !$0.isTemporary && !$0.isBlankChat && !$0.decryptionFailed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    
    // Computed property to check if user has premium access
    // This is now only used for premium models
    var hasPremiumAccess: Bool {
        guard let authManager = authManager else { return false }
        return authManager.isAuthenticated && authManager.hasActiveSubscription
    }
    
    // Computed property to check if user has access to chat features
    // This is used for chat history and multiple chats
    var hasChatAccess: Bool {
        return authManager?.isAuthenticated ?? false
    }
    // MARK: - Pagination Persistence
    
    private func paginationDefaultsKey(_ suffix: String) -> String? {
        guard let userId = currentUserId else { return nil }
        switch suffix {
        case "token": return Constants.StorageKeys.Sync.paginationToken(userId: userId)
        case "hasMore": return Constants.StorageKeys.Sync.paginationHasMore(userId: userId)
        case "active": return Constants.StorageKeys.Sync.paginationActive(userId: userId)
        case "loadedFirst": return Constants.StorageKeys.Sync.paginationLoadedFirst(userId: userId)
        case "attempted": return Constants.StorageKeys.Sync.paginationAttempted(userId: userId)
        default: return nil
        }
    }
    
    private func persistPaginationStateIfPossible() {
        guard shouldPersistPaginationState else { return }
        guard let userId = currentUserId else { return }
        if let token = paginationToken, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: Constants.StorageKeys.Sync.paginationToken(userId: userId))
        } else {
            UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.Sync.paginationToken(userId: userId))
        }
        UserDefaults.standard.set(hasMoreChats, forKey: Constants.StorageKeys.Sync.paginationHasMore(userId: userId))
        UserDefaults.standard.set(isPaginationActive, forKey: Constants.StorageKeys.Sync.paginationActive(userId: userId))
        UserDefaults.standard.set(hasLoadedInitialPage, forKey: Constants.StorageKeys.Sync.paginationLoadedFirst(userId: userId))
        UserDefaults.standard.set(hasAttemptedLoadMore, forKey: Constants.StorageKeys.Sync.paginationAttempted(userId: userId))
    }
    
    private func loadPersistedPaginationState() {
        guard let userId = currentUserId else { return }
        if let token = UserDefaults.standard.string(forKey: Constants.StorageKeys.Sync.paginationToken(userId: userId)) {
            paginationToken = token
        }
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.Sync.paginationHasMore(userId: userId)) != nil {
            hasMoreChats = UserDefaults.standard.bool(forKey: Constants.StorageKeys.Sync.paginationHasMore(userId: userId))
        }
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.Sync.paginationActive(userId: userId)) != nil {
            isPaginationActive = UserDefaults.standard.bool(forKey: Constants.StorageKeys.Sync.paginationActive(userId: userId))
        }
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.Sync.paginationLoadedFirst(userId: userId)) != nil {
            hasLoadedInitialPage = UserDefaults.standard.bool(forKey: Constants.StorageKeys.Sync.paginationLoadedFirst(userId: userId))
        }
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.Sync.paginationAttempted(userId: userId)) != nil {
            hasAttemptedLoadMore = UserDefaults.standard.bool(forKey: Constants.StorageKeys.Sync.paginationAttempted(userId: userId))
        }
        // Enable persistence after we've loaded any saved state to prevent clobbering
        shouldPersistPaginationState = true
    }
    
    // Get current user ID from auth manager
    private var currentUserId: String? {
        guard let authManager = authManager,
              authManager.isAuthenticated,
              let userId = authManager.localUserId else {
            return nil
        }
        return userId
    }
    
    // Computed property for verification status message
    var verificationStatusMessage: String {
        if isVerifying {
            return "Verifying privacy..."
        } else if isVerified {
            return "Chat is private."
        } else if let _ = verificationError {
            return "Verification failed."
        } else {
            return "Verification needed."
        }
    }
    
    init(authManager: AuthManager? = nil) {
        // Initialize with last selected model from AppConfig (which now persists)
        // The app should ensure AppConfig is initialized before creating ChatViewModel
        guard let model = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first else {
            // This should never happen in production if app initialization is correct
            fatalError("ChatViewModel cannot be initialized without available models. Ensure AppConfig loads models before creating ChatViewModel.")
        }
        self.currentModel = model
        // Load persisted reasoning preferences. Both default to the most
        // permissive setting (thinking on, medium effort) when no value has
        // been saved yet, matching the webapp.
        isLoadingPersistedSettings = true
        if let savedEffortRaw = UserDefaults.standard.string(
            forKey: Constants.StorageKeys.Settings.reasoningEffort
        ), let savedEffort = ReasoningEffort(rawValue: savedEffortRaw) {
            self.reasoningEffort = savedEffort
        }
        if UserDefaults.standard.object(
            forKey: Constants.StorageKeys.Settings.thinkingEnabled
        ) != nil {
            self.thinkingEnabled = UserDefaults.standard.bool(
                forKey: Constants.StorageKeys.Settings.thinkingEnabled
            )
        }
        isLoadingPersistedSettings = false

        if let savedTab = UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab),
           let tab = ChatStorageTab(rawValue: savedTab) {
            self.activeStorageTab = tab
        }
        // Force cloud tab when local-only mode is disabled
        if SettingsManager.shared.isCloudSyncEnabled && !SettingsManager.shared.isLocalOnlyModeEnabled {
            self.activeStorageTab = .cloud
        }

        // Load persisted last sync date (will be loaded per-user when auth is set)
        // Initial load happens in the authManager didSet
        
        // Store auth manager reference (will trigger initial sync via didSet if authenticated)
        self.authManager = authManager
        
        // Always create a new chat when the app is loaded initially.
        // authManager is nil at init time (set later via onAppear), so this always takes
        // the unauthenticated branch. The didSet on authManager moves the chat to the
        // correct array once auth state is known.
        let newChat = Chat.create(modelType: currentModel)
        currentChat = newChat
        chats = [newChat]
        isWebSearchEnabled = newChat.webSearchEnabled
        
        // Load any previously persisted pagination state (per-user)
        // Delay enabling persistence until after load to avoid overwriting saved values
        loadPersistedPaginationState()

        // Setup app lifecycle observers
        setupAppLifecycleObservers()
        setupSharedSettingsObserver()

        // Setup network status observer for automatic retry on reconnection
        setupNetworkStatusObserver()

        // Mirror the passkey recovery-skipped state so views observe it through the
        // view model rather than reaching into the passkey service directly.
        passkeyManager.$recoverySkipped
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPasskeyRecoverySkipped)

        // Initial sync will be triggered when authManager is set (see authManager didSet)

        // Sync rate limit state from SessionTokenManager to this view model
        rateLimit = SessionTokenManager.shared.rateLimitInfo
        SessionTokenManager.shared.onRateLimitChanged = { [weak self] info in
            Task { @MainActor in
                self?.rateLimit = info
            }
        }

        // Setup Tinfoil client immediately
        setupTinfoilClient()
    }
    
    deinit {
        // Stop auto-sync timer
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil

        // Stop stream update timers
        streamUpdateTimers.values.forEach { $0.invalidate() }
        streamUpdateTimers.removeAll()
        streamTasks.values.forEach { $0.cancel() }
        streamTasks.removeAll()

        // Cancel network status observer
        networkStatusCancellable?.cancel()
        networkStatusCancellable = nil

        // Remove app lifecycle observers
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willResignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = sharedSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupSharedSettingsObserver() {
        sharedSettingsObserver = NotificationCenter.default.addObserver(
            forName: .profileSharedSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let profile = notification.object as? ProfileData else { return }
            Task { @MainActor in
                self?.applySharedSettings(profile)
            }
        }
    }

    private func applySharedSettings(_ profile: ProfileData) {
        if let effort = profile.reasoningEffort,
           let parsedEffort = ReasoningEffort(rawValue: effort) {
            reasoningEffort = parsedEffort
        }
        if let thinkingEnabled = profile.thinkingEnabled {
            self.thinkingEnabled = thinkingEnabled
        }
    }
    
    /// Setup auto-sync timer to sync every 30 seconds
    private func setupAutoSyncTimer() {
        // Invalidate existing timer if any
        autoSyncTimer?.invalidate()

        // Do not start auto-sync when cloud sync is disabled
        if !SettingsManager.shared.isCloudSyncEnabled {
            return
        }

        // Do not start auto-sync until encryption key is set up
        if !EncryptionService.shared.hasEncryptionKey() {
            return
        }

        // Create timer that fires at regular intervals
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: Constants.Sync.chatSyncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Gate auto-sync if no encryption key is set
                if !EncryptionService.shared.hasEncryptionKey() {
                    return
                }

                // Only sync if authenticated
                guard self.authManager?.isAuthenticated == true else {
                    return
                }
                
                // Skip auto-sync if actively sending a message or streaming
                if !self.streamState.activeChatIds.isEmpty {
                    return
                }
                
                // Skip if current chat has active stream
                if let currentChat = self.currentChat, 
                   (currentChat.hasActiveStream || self.streamingTracker.isStreaming(currentChat.id)) {
                    return
                }
                
                
                // Perform sync in background
                // Use smart sync for periodic sync (checks if sync is needed first)
                let syncResult = await self.cloudSync.smartSync()

                // Update last sync date after successful sync
                self.lastSyncDate = Date()

                // If chats were downloaded or deleted remotely, reload the chat list
                if syncResult.downloaded > 0 || syncResult.deleted > 0 {
                    // Use intelligent update that preserves pagination
                    await self.updateChatsAfterSync()

                    // Force UI update
                    self.objectWillChange.send()

                    // Restore current chat selection if it still exists
                    if let currentChatId = self.currentChat?.id,
                       let location = self.findChatLocation(currentChatId) {
                        self.currentChat = self.chat(at: location)
                    }

                }

                // Also backup current chat if it has changes
                if let currentChat = await MainActor.run(body: { self.currentChat }),
                   !currentChat.messages.isEmpty,
                   !currentChat.hasActiveStream {
                    await self.cloudSync.backupChat(currentChat.id)
                }

                // Sync profile settings periodically
                await ProfileManager.shared.syncFromCloud()
            }
        }
        // Ensure the timer fires during UI interactions (scrolling, modal sheets)
        if let timer = autoSyncTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    /// Setup observers for app lifecycle events
    private func setupAppLifecycleObservers() {
        // Listen for app becoming active (returning from background)
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Proactively refresh the session token if it is expired or near
            // expiry so the first request after returning to the foreground
            // doesn't have to fail and retry. The attested client persists and
            // picks up the new token through its provider.
            Task { @MainActor in
                if SessionTokenManager.shared.needsRefresh {
                    await self?.refreshSessionTokenForRetry()
                }
            }

            // Add a small delay to allow auth state to stabilize, then retry client setup if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.retryClientSetup()
            }
            
            // Resume auto-sync timer if authenticated and cloud sync is enabled
            Task { @MainActor in
                if self?.authManager?.isAuthenticated == true && SettingsManager.shared.isCloudSyncEnabled {
                    // Skip sync if no encryption key is set
                    if !EncryptionService.shared.hasEncryptionKey() {
                        return
                    }

                    self?.setupAutoSyncTimer()

                    // Perform immediate sync when returning from background
                    if let syncResult = await self?.cloudSync.syncAllChats() {
                        // Update last sync date
                        self?.lastSyncDate = Date()

                        // Update chats if needed
                        if syncResult.downloaded > 0 || syncResult.deleted > 0 {
                            await self?.updateChatsAfterSync()
                        }
                    }
                }
            }
        }
        
        // Listen for app going to background
        willResignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Pause auto-sync timer
                self?.autoSyncTimer?.invalidate()
                self?.autoSyncTimer = nil
                
                // Do one final sync before going to background
                if self?.authManager?.isAuthenticated == true && SettingsManager.shared.isCloudSyncEnabled {
                    if let _ = await self?.cloudSync.syncAllChats() {
                        // Update last sync date
                        self?.lastSyncDate = Date()
                    }
                }
            }
        }
    }

    private func setupNetworkStatusObserver() {
        networkStatusCancellable = AppConfig.shared.networkMonitor.$isConnected
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isConnected in
                guard let self = self, isConnected else { return }

                // Only retry if verification failed (has error) and not currently initializing
                guard self.verificationError != nil && !self.isVerifying && !self.isClientInitializing else { return }

                // Retry after a short delay to let the network stabilize
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Verification.networkRetryDelaySeconds) { [weak self] in
                    self?.retryClientSetup()
                }
            }
    }

    private func setupTinfoilClient() {
        guard !isClientInitializing else {
            return
        }

        isClientInitializing = true
        verification.error = nil
        verification.isVerifying = true

        client = nil  // Just nil out the old client

        Task {
            do {
                await AppConfig.shared.waitForInitialization()
                // Pre-warm the cached token so the first request has a bearer.
                // The client then reads the live token per request via the
                // provider, so the bearer can rotate without rebuilding the
                // attested client or re-running enclave verification.
                _ = await AppConfig.shared.getSessionToken()

                client = try await TinfoilAI.create(
                    apiKeyProvider: { SessionTokenManager.shared.currentToken },
                    // Opt into the router's inline progress markers so
                    // live web search and URL-fetch status drives the
                    // same WebSearchState / URLFetchState UI the app
                    // already renders, without requiring a separate
                    // auxiliary stream.
                    tinfoilEvents: [.webSearch],
                    onVerification: { [weak self] verificationDoc in
                        DispatchQueue.main.async {
                            guard let self = self else { return }

                            self.verificationDocument = verificationDoc
                            self.verification.isVerifying = false

                            if let doc = verificationDoc {
                                self.verification.isVerified = doc.securityVerified
                                if !doc.securityVerified {
                                    self.verification.error = doc.getFirstError() ?? "Verification failed"
                                } else {
                                    self.verification.error = nil
                                }
                            } else {
                                self.verification.isVerified = false
                                self.verification.error = "No verification document received"
                            }
                        }
                    }
                )

                await MainActor.run {
                    self.isClientInitializing = false
                }
            } catch {
                await MainActor.run {
                    self.verification.isVerifying = false
                    self.isClientInitializing = false

                    if self.verificationDocument == nil {
                        self.verification.isVerified = false
                        self.verification.error = error.localizedDescription
                    }
                }
            }
        }
    }
    
    func retryClientSetup() {
        guard client == nil || (!isVerified && !isVerifying && verificationError != nil) else {
            return
        }

        guard streamState.activeChatIds.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retryClientSetup()
            }
            return
        }

        setupTinfoilClient()
    }
    
    // MARK: - Public Methods
    
    /// Switches the active storage tab and selects an appropriate chat
    func switchStorageTab(to tab: ChatStorageTab) {
        guard activeStorageTab != tab else { return }
        // Prevent switching to local when local-only mode is disabled
        if tab == .local && SettingsManager.shared.isCloudSyncEnabled && !SettingsManager.shared.isLocalOnlyModeEnabled {
            return
        }
        activeStorageTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab)

        let shouldBeLocal = tab == .local

        // If on a blank chat, switch to the blank chat for the target tab
        if currentChat?.isBlankChat == true {
            createNewChat(isLocalOnly: shouldBeLocal, focusInput: false)
            return
        }

        let targetList = shouldBeLocal ? localChats : chats
        if let first = targetList.first {
            selectChat(first)
        } else {
            createNewChat(isLocalOnly: shouldBeLocal, focusInput: false)
        }
    }

    /// Creates a new chat and sets it as the current chat
    func createNewChat(language: String? = nil, modelType: ModelType? = nil, isLocalOnly: Bool? = nil, projectId: String? = nil, focusInput: Bool = true) {
        // Allow creating new chats for all authenticated users
        guard hasChatAccess else { return }
        
        // Exit temporary mode when the user explicitly creates a fresh chat.
        if isTemporaryMode {
            if let temp = currentChat, temp.isTemporary {
                cancelGeneration(chatId: temp.id, announce: false)
                if temp.isLocalOnly {
                    localChats.removeAll { $0.id == temp.id }
                } else {
                    chats.removeAll { $0.id == temp.id }
                }
            }
            isTemporaryMode = false
            previousChatIdBeforeTemporary = nil
        }

        let targetProjectId = projectId ?? activeProject?.id
        let shouldBeLocal: Bool
        if targetProjectId != nil {
            shouldBeLocal = false
        } else if let explicit = isLocalOnly {
            shouldBeLocal = explicit
        } else if !SettingsManager.shared.isCloudSyncEnabled {
            shouldBeLocal = true
        } else if !SettingsManager.shared.isLocalOnlyModeEnabled {
            shouldBeLocal = false
        } else {
            shouldBeLocal = activeStorageTab == .local
        }

        // A reused blank represents a fresh chat, so reset its preference to
        // the current global default before selecting it.
        if shouldBeLocal {
            if let index = localChats.firstIndex(where: { $0.isBlankChat && $0.projectId == targetProjectId }) {
                localChats[index].webSearchEnabled = SettingsManager.shared.webSearchAvailable
                selectChat(localChats[index])
                shouldFocusInput = focusInput
                return
            }
        } else {
            if let index = chats.firstIndex(where: { $0.isBlankChat && $0.projectId == targetProjectId }) {
                chats[index].webSearchEnabled = SettingsManager.shared.webSearchAvailable
                selectChat(chats[index])
                shouldFocusInput = focusInput
                return
            }
        }
        
        // Create new chat with temporary ID (instant, no network call)
        let newChat = Chat.create(
            modelType: modelType ?? currentModel,
            language: language,
            userId: currentUserId,
            isLocalOnly: shouldBeLocal,
            projectId: targetProjectId
        )

        if shouldBeLocal {
            localChats.insert(newChat, at: 0)
        } else {
            chats.insert(newChat, at: 0)
        }
        selectChat(newChat)
        shouldFocusInput = focusInput
    }

    func loadProjects() async {
        guard hasChatAccess, SettingsManager.shared.isCloudSyncEnabled else {
            projects = []
            return
        }

        isLoadingProjects = true
        projectError = nil
        do {
            projects = try await projectStorage.loadProjects()
        } catch {
            projectError = error.localizedDescription
        }
        isLoadingProjects = false
    }

    @discardableResult
    func createProject(name: String? = nil) async -> Project? {
        guard hasChatAccess else { return nil }

        isLoadingProject = true
        projectError = nil
        do {
            let resolvedName = name ?? "My Project #\(projects.count + 1)"
            let project = try await projectStorage.createProject(
                CreateProjectData(name: resolvedName)
            )
            projects.insert(project, at: 0)
            await enterProject(projectId: project.id)
            isLoadingProject = false
            return project
        } catch {
            projectError = error.localizedDescription
            isLoadingProject = false
            return nil
        }
    }

    func enterProject(projectId: String) async {
        guard hasChatAccess else { return }

        isLoadingProject = true
        projectError = nil
        isViewingProjectChat = false
        do {
            let project = try await projectStorage.getProject(projectId)
            guard let project else {
                throw CloudStorageError.downloadFailed
            }

            let documents = try await projectStorage.listDocuments(projectId: projectId, includeContent: true)
            activeProject = project
            projectDocuments = documents

            let syncResult = await cloudSync.smartSync(projectId: projectId)
            if syncResult.downloaded > 0 || syncResult.uploaded > 0 || activeProjectChats.isEmpty {
                await loadProjectChatsIntoMemory(projectId: projectId)
            }

            createNewChat(isLocalOnly: false, projectId: projectId, focusInput: false)
        } catch {
            projectError = error.localizedDescription
        }
        isLoadingProject = false
    }

    func exitProject() {
        activeProject = nil
        projectDocuments = []
        projectError = nil
        isViewingProjectChat = false
        shouldExpandProjectsInSidebar = true
        createNewChat(isLocalOnly: false, focusInput: false)
    }

    func returnToProjectLanding() {
        guard let projectId = activeProject?.id else { return }
        isViewingProjectChat = false
        createNewChat(isLocalOnly: false, projectId: projectId, focusInput: false)
    }

    func openProjectChat(_ chat: Chat) {
        selectChat(chat)
        isViewingProjectChat = true
    }

    func startNewProjectChat() {
        guard let projectId = activeProject?.id else { return }
        createNewChat(isLocalOnly: false, projectId: projectId)
        isViewingProjectChat = true
    }

    func updateActiveProject(name: String? = nil, description: String? = nil, systemInstructions: String? = nil, memory: [MemoryFact]? = nil) async {
        guard let project = activeProject else { return }

        projectError = nil
        do {
            let update = UpdateProjectData(
                name: name,
                description: description,
                systemInstructions: systemInstructions,
                memory: memory
            )
            try await projectStorage.updateProject(project.id, data: update)
            var updated = project
            updated.name = name ?? updated.name
            updated.description = description ?? updated.description
            updated.systemInstructions = systemInstructions ?? updated.systemInstructions
            updated.memory = memory ?? updated.memory
            updated.updatedAt = ISO8601DateFormatter().string(from: Date())
            activeProject = updated
            if let index = projects.firstIndex(where: { $0.id == updated.id }) {
                projects[index] = updated
            }
        } catch {
            projectError = error.localizedDescription
        }
    }

    /// Permanently deletes every project the user owns, mirroring the
    /// webapp's bulk action. Throws so callers can surface the failure and
    /// leave local state untouched for a retry.
    @MainActor
    func deleteAllProjects() async throws {
        _ = try await projectStorage.deleteAllProjects()
        projects = []
        if activeProject != nil {
            exitProject()
        }
    }

    func deleteActiveProject() async {
        guard let project = activeProject else { return }

        projectError = nil
        do {
            try await projectStorage.deleteProject(project.id)
            projects.removeAll { $0.id == project.id }
            exitProject()
        } catch {
            projectError = error.localizedDescription
        }
    }

    func uploadProjectDocument(url: URL, filename: String) async {
        guard let project = activeProject else { return }

        isUploadingProjectDocument = true
        projectError = nil
        do {
            let markdown = try await DocumentConversionService.shared.convertToMarkdown(
                url: url,
                filename: filename
            )
            let contentType = DocumentConversionService.mimeType(for: filename)
            let document = try await projectStorage.uploadDocument(
                projectId: project.id,
                filename: filename,
                contentType: contentType,
                content: markdown
            )
            projectDocuments.append(document)
        } catch {
            projectError = error.localizedDescription
        }
        isUploadingProjectDocument = false
    }

    func deleteProjectDocument(_ documentId: String) async {
        guard let project = activeProject else { return }

        let existing = projectDocuments
        projectDocuments.removeAll { $0.id == documentId }
        do {
            try await projectStorage.deleteDocument(projectId: project.id, documentId: documentId)
        } catch {
            projectDocuments = existing
            projectError = error.localizedDescription
        }
    }

    func moveChatToProject(chatId: String, projectId: String) async {
        await updateChatProject(chatId: chatId, projectId: projectId)
    }

    func removeChatFromProject(chatId: String) async {
        await updateChatProject(chatId: chatId, projectId: nil)
    }

    private func updateChatProject(chatId: String, projectId: String?) async {
        guard hasChatAccess else { return }

        let wasCurrent = currentChat?.id == chatId
        guard var chat = chatForProjectMove(chatId) else { return }
        let wasLocal = chat.isLocalOnly

        chat.projectId = projectId
        chat.isLocalOnly = false
        chat.locallyModified = true
        chat.updatedAt = Date()

        if wasLocal {
            localChats.removeAll { $0.id == chatId }
            chats.insert(chat, at: min(1, chats.count))
            if let userId = currentUserId {
                try? await EncryptedFileStorage.local.deleteChat(chatId: chatId, userId: userId)
            }
        } else {
            replaceChat(chat)
        }

        if wasCurrent {
            currentChat = chat
        }

        saveChat(chat)

        // The upload itself carries the project membership (the enclave
        // stamps the row's project_id from the chat push metadata), so
        // backing up the chat IS the server-side move. If the upload
        // can't land right now the chat stays locallyModified and the
        // next sync retries it, like any other offline edit.
        await cloudSync.backupChat(chatId, ensureLatestUpload: true)
        if let projectId {
            await loadProjectChatsIntoMemory(projectId: projectId)
        }

        if wasCurrent, activeProject?.id != projectId {
            createNewChat(isLocalOnly: false, projectId: activeProject?.id)
        }
    }

    /// Sets (or clears) the prompt-library preset for the current chat. The
    /// preset's system prompt overrides the default for this conversation.
    func setPromptPreset(_ presetId: String?) {
        guard var chat = currentChat else { return }
        if let updated = updateChatInPlace(chat.id, update: { c in
            c.promptPresetId = presetId
            c.locallyModified = true
            c.updatedAt = Date()
        }) {
            saveChat(updated)
        } else {
            // Chat not yet in either array (e.g. a transient blank chat):
            // update the in-memory current chat so the preset still applies.
            chat.promptPresetId = presetId
            chat.locallyModified = true
            chat.updatedAt = Date()
            currentChat = chat
        }
    }

    /// Starts a fresh chat preloaded with the given prompt preset. Focus is
    /// deferred until the presenting sheet finishes dismissing (see
    /// `focusInputIfPending`), otherwise the keyboard would rise inside the
    /// dismissing sheet's layout instead of the chat's input area.
    func startChat(withPresetId presetId: String) {
        createNewChat(focusInput: false)
        setPromptPreset(presetId)
        focusInputAfterDismiss = true
    }

    /// Focuses the input if a flow requested it be deferred until a sheet
    /// dismissal completed. Call from the sheet's `onDismiss`.
    func focusInputIfPending() {
        guard focusInputAfterDismiss else { return }
        focusInputAfterDismiss = false
        shouldFocusInput = true
    }

    private func chatForProjectMove(_ chatId: String) -> Chat? {
        if let location = findChatLocation(chatId) {
            return chat(at: location)
        }
        return nil
    }

    private func loadProjectChatsIntoMemory(projectId: String) async {
        let projectChats = await loadProjectChatsFromStorage(projectId: projectId)
        for projectChat in projectChats {
            if let index = chats.firstIndex(where: { $0.id == projectChat.id }) {
                chats[index] = projectChat
            } else {
                chats.append(projectChat)
            }
        }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    private func loadProjectChatsFromStorage(projectId: String) async -> [Chat] {
        guard let userId = currentUserId else { return [] }
        let index = await Chat.loadChatIndex(userId: userId)
        let ids = index
            .filter {
                $0.projectId == projectId &&
                ($0.messageCount > 0 || $0.decryptionFailed || $0.titleState != .placeholder)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.id)
        return await Chat.loadChats(chatIds: ids, userId: userId)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Toggles temporary (incognito) chat mode. When enabled, the current chat
    /// is replaced with an ephemeral in-memory chat that is never persisted to
    /// disk or synced to the cloud. Disabling restores the previously active
    /// chat (or creates a new one if none was tracked).
    func toggleTemporaryMode() {
        guard hasChatAccess else { return }

        if isTemporaryMode {
            // Exit temporary mode: drop the ephemeral chat and restore previous.
            if let current = currentChat, current.isTemporary {
                cancelGeneration(chatId: current.id, announce: false)
                if current.isLocalOnly {
                    localChats.removeAll { $0.id == current.id }
                } else {
                    chats.removeAll { $0.id == current.id }
                }
            }

            isTemporaryMode = false
            let previousId = previousChatIdBeforeTemporary
            previousChatIdBeforeTemporary = nil

            if let previousId,
               let restored = chats.first(where: { $0.id == previousId })
                                ?? localChats.first(where: { $0.id == previousId }) {
                selectChat(restored)
            } else {
                createNewChat()
            }
        } else {
            // Enter temporary mode: snapshot the current chat ID and swap in a
            // brand-new ephemeral chat.
            previousChatIdBeforeTemporary = currentChat?.id

            guard let model = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first else {
                return
            }

            var temp = Chat(
                id: "temp-\(UUID().uuidString.lowercased())",
                title: "Temporary Chat",
                modelType: model,
                userId: currentUserId,
                isLocalOnly: true,
                webSearchEnabled: SettingsManager.shared.webSearchAvailable
            )
            temp.isTemporary = true

            // Track in localChats so existing flows (selection, message rendering)
            // see it. It is filtered out of the sidebar via `isBlankChat`/sort
            // logic and never persisted thanks to the `isTemporary` guards in
            // `Chat.saveChat` / `ChatViewModel.saveChat`.
            localChats.insert(temp, at: 0)
            isTemporaryMode = true
            selectChat(temp)
            shouldFocusInput = true
        }
    }

    /// Selects a chat as the current chat
    func selectChat(_ chat: Chat) {
        // If the user picked a different chat while in temporary mode, drop
        // the ephemeral chat and exit temporary mode. The selected chat takes
        // over normally below.
        if isTemporaryMode && !chat.isTemporary {
            if let temp = currentChat, temp.isTemporary {
                cancelGeneration(chatId: temp.id, announce: false)
                if temp.isLocalOnly {
                    localChats.removeAll { $0.id == temp.id }
                } else {
                    chats.removeAll { $0.id == temp.id }
                }
            }
            isTemporaryMode = false
            previousChatIdBeforeTemporary = nil
        }

        // Find the most up-to-date version of the chat in both arrays
        let chatToSelect: Chat
        if chat.isLocalOnly {
            if let index = localChats.firstIndex(where: { $0.id == chat.id }) {
                chatToSelect = localChats[index]
            } else {
                chatToSelect = chat
                localChats.append(chatToSelect)
            }
        } else {
            if let index = chats.firstIndex(where: { $0.id == chat.id }) {
                chatToSelect = chats[index]
            } else {
                chatToSelect = chat
                chats.append(chatToSelect)
            }
        }

        currentChat = chatToSelect

        // Update the current model to match the chat's model
        if currentModel != chatToSelect.modelType {
            changeModel(to: chatToSelect.modelType, shouldUpdateChat: false)
        }

        // Lazy-load full-res images for v1 synced chats
        let hasUnfetchedImages = chatToSelect.messages.contains { msg in
            msg.attachments.contains { $0.type == .image && $0.base64 == nil && $0.encryptionKey != nil }
        }
        if hasUnfetchedImages {
            let chatId = chatToSelect.id
            Task {
                let loadedImages = await CloudStorageService.shared.loadImages(in: chatToSelect.messages)
                guard !loadedImages.isEmpty, self.currentChat?.id == chatId else { return }
                // Merge loaded base64 data into the current messages by attachment ID,
                // rather than replacing the whole array with a stale snapshot.
                self.applyLoadedImages(loadedImages, toChatId: chatId)
            }
        }
    }

    func setWebSearchEnabled(_ enabled: Bool) {
        guard var chat = currentChat else {
            if isWebSearchEnabled != enabled {
                isWebSearchEnabled = enabled
            }
            return
        }

        guard chat.webSearchEnabled != enabled else { return }
        if isWebSearchEnabled != enabled {
            isWebSearchEnabled = enabled
        }

        chat.webSearchEnabled = enabled
        chat.locallyModified = true
        chat.updatedAt = Date()
        currentChat = chat
        replaceChat(chat)
        saveChat(chat)
    }
    
    /// Merge fetched image base64 data into the current messages of a chat by attachment ID.
    /// This avoids replacing the entire messages array, preventing a stale snapshot from
    /// overwriting messages that may have been updated by sync while images were loading.
    private func applyLoadedImages(_ images: [String: String], toChatId chatId: String) {
        func mergeIntoMessages(_ messages: inout [Message]) {
            for msgIdx in messages.indices {
                for attIdx in messages[msgIdx].attachments.indices {
                    let attId = messages[msgIdx].attachments[attIdx].id
                    if let b64 = images[attId] {
                        messages[msgIdx].attachments[attIdx].base64 = b64
                    }
                }
            }
        }

        if currentChat?.id == chatId {
            var updated = currentChat!
            mergeIntoMessages(&updated.messages)
            currentChat = updated
        }
        if let idx = chats.firstIndex(where: { $0.id == chatId }) {
            mergeIntoMessages(&chats[idx].messages)
        }
    }

    /// Deletes a chat by ID
    func deleteChat(_ id: String) {
        // Allow deleting chats for all authenticated users
        guard hasChatAccess else { return }

        let isLocal: Bool
        if localChats.contains(where: { $0.id == id }) {
            isLocal = true
        } else if chats.contains(where: { $0.id == id }) {
            isLocal = false
        } else {
            return
        }

        let userId = currentUserId
        let canceledStreamTask = cancelGeneration(
            chatId: id,
            announce: false
        )

        // Delete from file storage and cloud
        Task {
            await canceledStreamTask?.value
            await drainPendingSaves()

            if !isLocal && SettingsManager.shared.isCloudSyncEnabled {
                do {
                    try await cloudSync.deleteFromCloud(id)
                } catch {
                    syncErrors.append("Failed to delete chat: \(error.localizedDescription)")
                    return
                }
            } else if !isLocal {
                // Mark as deleted for cloud sync (local-only chats are never uploaded)
                DeletedChatsTracker.shared.markAsDeleted(id)
            }

            await Chat.deleteChatFromStorage(chatId: id, userId: userId)

            if let index = localChats.firstIndex(where: { $0.id == id }) {
                localChats.remove(at: index)
            } else if let index = chats.firstIndex(where: { $0.id == id }) {
                chats.remove(at: index)
            }

            // If the deleted chat was the current chat, select another one
            if currentChat?.id == id {
                let activeList = isLocal ? localChats : chats
                if let first = activeList.first {
                    currentChat = first
                } else {
                    createNewChat(isLocalOnly: isLocal)
                }
            }
        }
    }
    
    /// Finds a chat by ID in localChats or chats and returns (inout reference via index, array identity)
    private func findChatLocation(_ id: String) -> (isLocal: Bool, index: Int)? {
        if let index = localChats.firstIndex(where: { $0.id == id }) {
            return (isLocal: true, index: index)
        }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            return (isLocal: false, index: index)
        }
        return nil
    }

    /// Returns the chat for a given location tuple.
    private func chat(at location: (isLocal: Bool, index: Int)) -> Chat {
        location.isLocal ? localChats[location.index] : chats[location.index]
    }

    /// Updates a chat in whichever array it belongs to
    @discardableResult
    private func updateChatInPlace(_ id: String, update: (inout Chat) -> Void) -> Chat? {
        if let index = localChats.firstIndex(where: { $0.id == id }) {
            update(&localChats[index])
            let updated = localChats[index]
            if currentChat?.id == id { currentChat = updated }
            return updated
        }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            update(&chats[index])
            let updated = chats[index]
            if currentChat?.id == id { currentChat = updated }
            return updated
        }
        return nil
    }

    /// Replaces a chat in whichever array (localChats or chats) it belongs to.
    /// If the chat isn't in either array, inserts it into the appropriate one.
    private func replaceChat(_ updatedChat: Chat) {
        if let index = localChats.firstIndex(where: { $0.id == updatedChat.id }) {
            localChats[index] = updatedChat
        } else if let index = chats.firstIndex(where: { $0.id == updatedChat.id }) {
            chats[index] = updatedChat
        } else if !updatedChat.isBlankChat {
            // Chat not in either array — insert into the appropriate one
            if updatedChat.isLocalOnly || !SettingsManager.shared.isCloudSyncEnabled {
                localChats.insert(updatedChat, at: min(1, localChats.count))
            } else {
                chats.insert(updatedChat, at: min(1, chats.count))
            }
        }
    }

    /// Updates a chat's title
    func updateChatTitle(_ id: String, newTitle: String) {
        // Allow updating chat titles for all authenticated users
        guard hasChatAccess else { return }

        if let updated = updateChatInPlace(id, update: { chat in
            let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                chat.title = Chat.placeholderTitle
                chat.titleState = .placeholder
            } else {
                chat.title = trimmed
                chat.titleState = .manual
            }
            chat.locallyModified = true
            chat.updatedAt = Date()
        }) {
            saveChat(updated)
        }
    }

    /// Resolves a pending input-surface GenUI tool call: writes the
    /// resolution onto the matching `tool_call` block on the message's
    /// timeline (the cross-platform wire shape) and submits the result
    /// text as a new user message so the conversation continues
    /// naturally. Mirrors the webapp's `resolveInputToolCall`.
    func resolveGenUIToolCall(
        toolCallId: String,
        resultText: String,
        resultData: JSONValue?
    ) {
        guard !isLoading else { return }
        guard var chat = currentChat else { return }

        var didResolve = false
        for index in chat.messages.indices.reversed() {
            guard chat.messages[index].role == .assistant else { continue }
            guard chat.messages[index].toolCalls.contains(where: { $0.id == toolCallId }) else {
                break
            }
            var timeline = chat.messages[index].timeline ?? []
            // If the timeline is missing this tool_call block (e.g. an
            // older message reconstructed from `toolCalls` only), seed
            // a block first so `resolve` has something to update.
            if !timeline.contains(where: {
                guard let object = $0.objectValue else { return false }
                return object["type"]?.stringValue == "tool_call"
                    && object["toolCallId"]?.stringValue == toolCallId
            }) {
                if let toolCall = chat.messages[index].toolCalls.first(where: { $0.id == toolCallId }) {
                    TimelineToolCalls.upsertStreamingBlock(
                        in: &timeline,
                        toolCallId: toolCallId,
                        name: toolCall.name,
                        arguments: toolCall.arguments
                    )
                }
            }
            TimelineToolCalls.resolve(
                in: &timeline,
                toolCallId: toolCallId,
                text: resultText,
                data: resultData
            )
            chat.messages[index].timeline = timeline
            didResolve = true
            break
        }

        guard didResolve else { return }

        updateChat(chat)
        sendMessage(text: resultText)
    }

    /// Sends a user message and generates a response
    func sendMessage(text: String) {
        guard !isLoading else { return }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        guard hasText || hasAttachments else { return }
        guard attachmentsAreReadyToSend(pendingAttachments) else { return }

        // Block send when free-tier requests are exhausted
        #if DEBUG
        if let rl = rateLimit {
            print("[Chat] sendMessage: rateLimit \(rl.remaining)/\(rl.maxRequests)")
        } else {
            print("[Chat] sendMessage: no rate limit info (premium or not yet fetched)")
        }
        #endif
        // The free-tier daily limit blocks sending and offers an upgrade; the
        // subscriber hourly cap is transient, so it neither blocks input nor
        // shows the paywall.
        if let rl = rateLimit, rl.remaining <= 0, rl.kind != .hourly {
            showRateLimitPaywall = true
            return
        }

        // Optimistically decrement the remaining request count
        SessionTokenManager.shared.snapshotAndDecrementRemaining()

        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        let messageAttachments = pendingAttachments
        clearPendingAttachments(acknowledgeSharedImports: false)

        // Create and add user message — attachments carry all data
        let userMessage = Message(
            role: .user,
            content: text,
            attachments: messageAttachments
        )
        addMessage(userMessage)
        for requestID in messageAttachments.compactMap(\.sharedImportRequestID) {
            SharedImportCoordinator.shared.acknowledge(requestID: requestID)
        }

        // If this is the first message, mark as modified (title will be generated after assistant reply)
        if var chat = currentChat, chat.messages.count == 1 {
            chat.updatedAt = Date()
            chat.locallyModified = true
            updateChat(chat)
        }

        generateResponse()
    }

    // MARK: - Attachment Management

    func addDocumentAttachment(
        url: URL,
        fileName: String,
        sharedImportRequestID: UUID? = nil
    ) {
        attachmentError = nil

        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(
            id: attachmentId,
            type: .document,
            fileName: fileName,
            sharedImportRequestID: sharedImportRequestID,
            processingState: .processing
        )
        pendingAttachments.append(attachment)

        Task {
            do {
                let text = try await DocumentProcessingService.shared.extractText(from: url)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

                attachment.textContent = text
                attachment.fileSize = fileSize
                attachment.processingState = .completed

                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
            } catch {
                attachment.processingState = .failed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                attachmentError = error.localizedDescription
            }
        }
    }

    func addImageAttachment(
        data: Data,
        fileName: String,
        sharedImportRequestID: UUID? = nil
    ) {
        attachmentError = nil

        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(
            id: attachmentId,
            type: .image,
            fileName: fileName,
            fileSize: Int64(data.count),
            sharedImportRequestID: sharedImportRequestID,
            processingState: .processing
        )
        pendingAttachments.append(attachment)

        Task {
            do {
                let processed = try await ImageProcessingService.shared.processImage(data: data)

                attachment.mimeType = Constants.Attachments.defaultImageMimeType
                attachment.base64 = processed.base64
                attachment.thumbnailBase64 = processed.thumbnailBase64
                attachment.fileSize = processed.compressedSize
                attachment.processingState = .completed

                // Build metadata description for cross-platform compatibility
                let sizeKB = processed.compressedSize / 1024
                attachment.description = "\(fileName) — \(processed.width)×\(processed.height) JPEG, \(sizeKB) KB"

                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                pendingImageThumbnails[attachmentId] = processed.thumbnailBase64
            } catch {
                attachment.processingState = .failed
                if let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }) {
                    pendingAttachments[index] = attachment
                }
                attachmentError = error.localizedDescription
            }
        }
    }

    func removePendingAttachment(id: String) {
        let sharedImportRequestID = pendingAttachments
            .first(where: { $0.id == id })?
            .sharedImportRequestID
        pendingAttachments.removeAll { $0.id == id }
        pendingImageThumbnails.removeValue(forKey: id)
        if let sharedImportRequestID {
            SharedImportCoordinator.shared.acknowledge(requestID: sharedImportRequestID)
        }
        if pendingAttachments.isEmpty {
            attachmentError = nil
        }
    }

    func clearPendingAttachments(acknowledgeSharedImports: Bool = true) {
        let sharedImportRequestIDs = pendingAttachments.compactMap(\.sharedImportRequestID)
        pendingAttachments.removeAll()
        pendingImageThumbnails.removeAll()
        attachmentError = nil
        if acknowledgeSharedImports {
            for requestID in sharedImportRequestIDs {
                SharedImportCoordinator.shared.acknowledge(requestID: requestID)
            }
        }
    }

    /// Generates an assistant response for the current conversation (expects user message to already be in chat)
    private func generateResponse() {
        guard let initialChat = currentChat,
              !streamState.isStreaming(chatId: initialChat.id) else {
            return
        }

        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        AccessibilityAnnouncer.announce(Constants.Accessibility.generatingResponse)

        // Create initial empty assistant message as a placeholder
        let assistantMessage = Message(role: .assistant, content: "", isCollapsed: true)
        addMessage(assistantMessage)

        guard var updatedStreamChat = currentChat else { return }
        let streamChatId = updatedStreamChat.id
        updatedStreamChat.hasActiveStream = true
        updateChat(updatedStreamChat)
        let streamChat = updatedStreamChat
        streamState.start(chatId: streamChatId)
        streamingTracker.startStreaming(streamChatId)

        let conversationMessages = streamChat.messages
        let streamModel = currentModel
        let streamProject = activeProject
        let streamProjectDocuments = projectDocuments
        let streamReasoningEffort = reasoningEffort
        let streamThinkingEnabled = thinkingEnabled
        let streamWebSearchEnabled = isWebSearchEnabled
            && SettingsManager.shared.webSearchAvailable
        let summaryService = ThinkingSummaryService()
        thinkingSummaryServices[streamChatId] = summaryService
        
        // Create and start a new task for the streaming request
        let streamTask = Task<Void, Never> {
            // Begin background task to allow stream to complete if app goes to background
            var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: Constants.Sync.backgroundTaskName) {
                // Clean up if system terminates the background task
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
            
            defer {
                // Always end the background task when done
                if backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskId)
                }
            }
            
            var hasRetriedWithFreshKey = false

            retryLoop: do {
                // Wait for client initialization if needed
                if client == nil || isClientInitializing {
                    // If client setup hasn't started, start it
                    if client == nil {
                        setupTinfoilClient()
                    }

                    // Wait for initialization to complete with timeout
                    let maxWaitTime = Constants.Sync.clientInitTimeoutSeconds
                    let startTime = Date()

                    while isClientInitializing && Date().timeIntervalSince(startTime) < maxWaitTime {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    }
                }

                guard let client = client, !isClientInitializing else {
                    throw NSError(domain: "TinfoilChat", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Service temporarily unavailable. Please try again."])
                }

                // Acquire the inference token before streaming. The per-account
                // hourly cap is enforced when the token is minted, not on the
                // inference request, so surfacing it here lets us abort cleanly
                // instead of firing a request that can only fail. The retry pass
                // forces a fresh mint to bypass a stale cached token.
                try await SessionTokenManager.shared.acquireTokenForSend(
                    forceRefresh: hasRetriedWithFreshKey
                )

                // Resolve the (possibly Auto) selection into a representative
                // model plus an ordered candidate list. Preferences narrow the
                // Auto candidates: multimodal when the turn carries images, and
                // tool-calling when web search or GenUI tools may be used.
                let turnHasImages = conversationMessages.contains { message in
                    message.attachments.contains { $0.type == .image }
                }
                let webSearchEnabled = streamWebSearchEnabled
                let modelSelection = AppConfig.shared.resolveModelSelection(
                    streamModel,
                    preferMultimodal: turnHasImages,
                    preferToolCalling: webSearchEnabled || SettingsManager.shared.genUIEnabled
                )
                let representativeModel = modelSelection.representative

                // Create the stream with proper parameters
                let modelId = representativeModel.modelName
                
                // Add system message first with language preference
                let settingsManager = SettingsManager.shared
                let profileManager = ProfileManager.shared
                var systemPrompt: String
                var suppressDefaultRules = false
                
                // Precedence: per-chat prompt preset > custom prompt toggle > default
                if let preset = profileManager.promptPreset(for: streamChat.promptPresetId) {
                    systemPrompt = preset.systemPrompt
                } else if let customPrompt = profileManager.getCustomSystemPrompt() {
                    systemPrompt = customPrompt
                    suppressDefaultRules = !ProfileManager.systemPromptHasContent(customPrompt)
                } else if settingsManager.isUsingCustomPrompt {
                    systemPrompt = ProfileManager.normalizeSystemPromptForSending(settingsManager.customSystemPrompt)
                    suppressDefaultRules = !ProfileManager.systemPromptHasContent(systemPrompt)
                } else {
                    systemPrompt = AppConfig.shared.systemPrompt
                }
                
                // Replace MODEL_NAME placeholder with current model name
                systemPrompt = systemPrompt.replacingOccurrences(of: "{MODEL_NAME}", with: representativeModel.fullName)
                
                // Replace language placeholder - use ProfileManager language first, then settings preference
                let languageToUse: String
                if !profileManager.language.isEmpty && profileManager.language != "English" {
                    // Use the language from ProfileManager
                    languageToUse = profileManager.language
                } else if settingsManager.selectedLanguage != "System" {
                    // Use the language from settings
                    languageToUse = settingsManager.selectedLanguage
                } else if let chatLanguage = streamChat.language {
                    // Fall back to chat's language if set
                    languageToUse = chatLanguage
                } else {
                    // Default to English
                    languageToUse = "English"
                }
                systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: languageToUse)
                
                // Add personalization - use ProfileManager first, then fall back to SettingsManager.
                // ProfileManager returns a fully-formed `<user_preferences>` block; the
                // SettingsManager fallback already does the same.
                var personalizationXML = ""
                if let profilePersonalization = profileManager.getPersonalizationPrompt() {
                    personalizationXML = profilePersonalization
                } else {
                    personalizationXML = settingsManager.generateUserPreferencesXML()
                }
                
                if !personalizationXML.isEmpty {
                    systemPrompt = systemPrompt.replacingOccurrences(of: "{USER_PREFERENCES}", with: personalizationXML)
                } else {
                    systemPrompt = systemPrompt.replacingOccurrences(of: "{USER_PREFERENCES}", with: "")
                }
                
                // Add current date/time and timezone
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let currentDateTime = dateFormatter.string(from: Date())
                let timezone = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
                
                systemPrompt = systemPrompt.replacingOccurrences(of: "{CURRENT_DATETIME}", with: currentDateTime)
                systemPrompt = systemPrompt.replacingOccurrences(of: "{TIMEZONE}", with: timezone)
                systemPrompt = ProjectContextBuilder.applyProjectContext(
                    to: systemPrompt,
                    project: streamProject,
                    documents: streamProjectDocuments
                )
                
                // Process rules with same replacements
                var processedRules = suppressDefaultRules ? "" : AppConfig.shared.rules
                if !processedRules.isEmpty {
                    processedRules = processedRules.replacingOccurrences(of: "{MODEL_NAME}", with: representativeModel.fullName)
                    processedRules = processedRules.replacingOccurrences(of: "{LANGUAGE}", with: languageToUse)

                    if !personalizationXML.isEmpty {
                        processedRules = processedRules.replacingOccurrences(of: "{USER_PREFERENCES}", with: personalizationXML)
                    } else {
                        processedRules = processedRules.replacingOccurrences(of: "{USER_PREFERENCES}", with: "")
                    }

                    processedRules = processedRules.replacingOccurrences(of: "{CURRENT_DATETIME}", with: currentDateTime)
                    processedRules = processedRules.replacingOccurrences(of: "{TIMEZONE}", with: timezone)
                }

                // Use ChatQueryBuilder to create query with model-specific system prompt handling
                let chatQuery = ChatQueryBuilder.buildQuery(
                    modelId: modelId,
                    systemPrompt: systemPrompt,
                    rules: processedRules,
                    conversationMessages: conversationMessages,
                    contextWindow: representativeModel.contextWindow,
                    webSearchEnabled: webSearchEnabled,
                    isMultimodal: representativeModel.isMultimodal,
                    reasoningConfig: representativeModel.reasoningConfig,
                    reasoningEffort: streamReasoningEffort,
                    thinkingEnabled: streamThinkingEnabled,
                    genUIEnabled: SettingsManager.shared.genUIEnabled,
                    autoCandidates: modelSelection.autoCandidates
                )

                let hapticEnabled = SettingsManager.shared.hapticFeedbackEnabled
                let hapticGenerator: UIImpactFeedbackGenerator? = hapticEnabled
                    ? UIImpactFeedbackGenerator(style: .light)
                    : nil
                hapticGenerator?.prepare()

                // Carry over any partial message state (a retry after a
                // mid-stream auth refresh resumes into the same message).
                var initialResponseContent = ""
                var initialThoughts: String? = nil
                var initialGenerationTime: TimeInterval? = nil
                var initialIsThinking = false
                if !streamChat.messages.isEmpty,
                   let lastIndex = streamChat.messages.indices.last {
                    initialResponseContent = streamChat.messages[lastIndex].content
                    initialThoughts = streamChat.messages[lastIndex].thoughts
                    initialGenerationTime = streamChat.messages[lastIndex].generationTimeSeconds
                    initialIsThinking = streamChat.messages[lastIndex].isThinking
                }

                // All per-chunk parsing state (event markers, chunkers, the
                // thinking state machine, tool calls, web search bookkeeping)
                // lives in the processor so the stream can be consumed off
                // the main actor.
                let processor = StreamingResponseProcessor(
                    isWebSearchEnabled: webSearchEnabled,
                    hapticEnabled: hapticEnabled,
                    responseContent: initialResponseContent,
                    currentThoughts: initialThoughts,
                    generationTimeSeconds: initialGenerationTime,
                    isInThinkingMode: initialIsThinking
                )

                // Web search progress now rides inline with the model's
                // content as `<tinfoil-event>` markers (opted into via
                // the `tinfoilEvents: [.webSearch]` flag on create).
                // Decoding happens inside the chunk loop below via
                // TinfoilEventParser; the SDK-level callback variant is
                // no longer needed because the router emits nothing
                // auxiliary on the chat stream.
                let stream: AsyncThrowingStream<ChatStreamResult, Error> = client.chatsStream(query: chatQuery)

                // Applies one decoded marker event to the current chat.
                // Mirrors the behavior the legacy SDK onWebSearchEvent
                // callback used to provide, but driven off the inline
                // marker stream so the app stays in sync with router
                // progress without a second SSE channel.
                let applyWebSearchCallEvent: @MainActor (TinfoilWebSearchCallEvent) -> Void = { [weak self] event in
                    guard let self = self else { return }
                    // Look up the streaming chat by ID, not self.currentChat,
                    // so an event landing after the user switched chats never
                    // writes search state into the newly selected chat.
                    let sid = streamChatId
                    guard let location = self.findChatLocation(sid) else { return }
                    var chat = self.chat(at: location)
                    guard !chat.messages.isEmpty,
                          let lastIndex = chat.messages.indices.last else { return }
                    if event.action?.type == "open_page", let url = event.action?.url {
                        let fetchId = event.itemId ?? url
                        switch event.status {
                        case .inProgress, .searching:
                            if !chat.messages[lastIndex].urlFetches.contains(where: { $0.id == fetchId }) {
                                chat.messages[lastIndex].urlFetches.append(
                                    URLFetchState(id: fetchId, url: url, status: .fetching)
                                )
                                processor.appendURLFetchSegment(fetchId)
                            }
                        case .completed:
                            if let idx = chat.messages[lastIndex].urlFetches.firstIndex(where: { $0.id == fetchId }) {
                                chat.messages[lastIndex].urlFetches[idx].status = .completed
                            }
                        case .failed:
                            if let idx = chat.messages[lastIndex].urlFetches.firstIndex(where: { $0.id == fetchId }) {
                                chat.messages[lastIndex].urlFetches[idx].status = .failed
                            }
                        case .blocked:
                            if let idx = chat.messages[lastIndex].urlFetches.firstIndex(where: { $0.id == fetchId }) {
                                chat.messages[lastIndex].urlFetches[idx].status = .blocked
                            }
                        }
                        chat.messages[lastIndex].segments = processor.currentSegments
                        self.updateChat(chat, throttleForStreaming: true)
                        return
                    }

                    let existingSources = chat.messages[lastIndex].webSearchState?.sources ?? []
                    switch event.status {
                    case .inProgress, .searching:
                        processor.markWebSearchStarted()
                        let id = event.itemId ?? processor.allocateSearchId()
                        processor.upsertWebSearch(
                            WebSearchInstance(
                                id: id,
                                query: event.action?.query,
                                status: .searching,
                                sources: existingSources,
                                reason: nil
                            )
                        )
                        chat.messages[lastIndex].webSearchState = WebSearchState(
                            query: event.action?.query,
                            status: .searching,
                            sources: existingSources
                        )
                        self.streamState.setWebSearchSummary(
                            event.action?.query.map { "Searching the web: \($0)" } ?? "Searching the web",
                            chatId: sid
                        )
                    case .completed:
                        let eventSources = event.sources?.compactMap { source -> WebSearchSource? in
                            guard let url = source.url, !url.isEmpty else { return nil }
                            return WebSearchSource(title: source.title ?? url, url: url)
                        }
                        if let existing = processor.findSearchInstance(matching: event.itemId) {
                            // Preserve any sources already collected for this
                            // instance when the completion payload doesn't
                            // carry a non-empty sources list of its own.
                            let mergedSources: [WebSearchSource]?
                            if let eventSources, !eventSources.isEmpty {
                                mergedSources = eventSources
                            } else {
                                mergedSources = existing.sources
                            }
                            processor.upsertWebSearch(
                                WebSearchInstance(
                                    id: existing.id,
                                    query: existing.query,
                                    status: .completed,
                                    sources: mergedSources,
                                    reason: existing.reason
                                )
                            )
                        }
                        if let eventSources, !eventSources.isEmpty {
                            var merged = chat.messages[lastIndex].webSearchState?.sources ?? []
                            var seen = Set(merged.map(\.url))
                            for source in eventSources where seen.insert(source.url).inserted {
                                merged.append(source)
                            }
                            chat.messages[lastIndex].webSearchState?.sources = merged
                        }
                        chat.messages[lastIndex].webSearchState?.status = .completed
                        self.streamState.setWebSearchSummary(nil, chatId: sid)
                    case .failed:
                        let eventSources = event.sources?.compactMap { source -> WebSearchSource? in
                            guard let url = source.url, !url.isEmpty else { return nil }
                            return WebSearchSource(title: source.title ?? url, url: url)
                        } ?? []
                        if let existing = processor.findSearchInstance(matching: event.itemId) {
                            processor.upsertWebSearch(
                                WebSearchInstance(
                                    id: existing.id,
                                    query: existing.query,
                                    status: .failed,
                                    sources: eventSources,
                                    reason: existing.reason
                                )
                            )
                        }
                        chat.messages[lastIndex].webSearchState?.status = .failed
                        self.streamState.setWebSearchSummary(nil, chatId: sid)
                    case .blocked:
                        let existing = processor.findSearchInstance(matching: event.itemId)
                        let id = existing?.id ?? event.itemId ?? processor.allocateSearchId()
                        processor.upsertWebSearch(
                            WebSearchInstance(
                                id: id,
                                query: event.action?.query ?? existing?.query,
                                status: .blocked,
                                sources: nil,
                                reason: event.error?.code
                            )
                        )
                        chat.messages[lastIndex].webSearchState = WebSearchState(
                            query: event.action?.query,
                            status: .blocked,
                            reason: event.error?.code
                        )
                        self.streamState.setWebSearchSummary(nil, chatId: sid)
                    }
                    chat.messages[lastIndex].segments = processor.currentSegments
                    chat.messages[lastIndex].webSearches = processor.currentWebSearches
                    self.updateChat(chat, throttleForStreaming: true)
                }

                // Consume the stream off the main actor: all per-chunk parsing
                // happens in the processor on this detached task, and the main
                // actor is only hopped to for rare event application, haptics,
                // and the throttled snapshot updates.
                let consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                    var lastUIUpdateTime = Date.distantPast
                    let uiUpdateInterval: TimeInterval = Constants.Streaming.uiUpdateInterval
                    // Latest thoughts awaiting a summary request; forwarded with
                    // the next throttled snapshot so summary generation does not
                    // force a main-actor hop per reasoning chunk.
                    var pendingSummaryThoughts: String? = nil

                    for try await chunk in stream {
                        if Task.isCancelled { break }

                        let parsed = processor.parse(chunk)

                        // Apply decoded marker events on the main actor before
                        // processing the chunk's text. The loop suspends until
                        // each event lands, so event handling stays ordered
                        // relative to the streamed text around it and the
                        // processor is never touched concurrently.
                        for event in parsed.events {
                            await applyWebSearchCallEvent(event)
                        }

                        let outcome = processor.process(parsed)

                        if outcome.shouldTickHaptic {
                            await MainActor.run {
                                hapticGenerator?.impactOccurred(intensity: 0.5)
                            }
                        }

                        for action in outcome.summaryActions {
                            switch action {
                            case .beginThinkingSession:
                                pendingSummaryThoughts = nil
                                await MainActor.run {
                                    summaryService.reset()
                                }
                            case .endThinkingSession:
                                pendingSummaryThoughts = nil
                                await MainActor.run {
                                    summaryService.reset()
                                    self?.streamState.setThinkingSummary(nil, chatId: streamChatId)
                                }
                            case .generate(let thoughts):
                                pendingSummaryThoughts = thoughts
                            }
                        }

                        // Update UI at a throttled rate to avoid overwhelming SwiftUI with diffs
                        let now = Date()
                        if outcome.didMutateState && now.timeIntervalSince(lastUIUpdateTime) >= uiUpdateInterval {
                            lastUIUpdateTime = now
                            let snapshot = processor.snapshot()
                            let thoughtsForSummary = pendingSummaryThoughts
                            pendingSummaryThoughts = nil
                            await MainActor.run {
                                guard let self else { return }
                                self.applyStreamSnapshot(snapshot, streamChatId: streamChatId)
                                if let thoughtsForSummary {
                                    summaryService.generateSummary(thoughts: thoughtsForSummary) { [weak self] summary in
                                        guard self?.streamState.isStreaming(chatId: streamChatId) == true else { return }
                                        self?.streamState.setThinkingSummary(summary, chatId: streamChatId)
                                    }
                                }
                            }
                        }
                    }

                    processor.finishStream()
                }

                // Propagate cancellation from cancelGeneration (which cancels
                // the outer task) into the detached stream consumer.
                try await withTaskCancellationHandler {
                    try await consumeTask.value
                } onCancel: {
                    consumeTask.cancel()
                }
                try Task.checkCancellation()

                let finalSnapshot = processor.snapshot()

                // Finalize message content and prepare chat for save
                // Look up the streaming chat by ID, not self.currentChat, because
                // the user may have navigated away or toggled sync mid-stream.
                var finalizedChat: Chat? = await MainActor.run {
                    let sid = streamChatId
                    guard let location = self.findChatLocation(sid) else {
                        self.finishStreamState(chatId: sid)
                        self.streamingTracker.endStreaming(sid)
                        return nil
                    }
                    var chat = self.chat(at: location)
                    chat.hasActiveStream = false

                    self.flushPendingStreamUpdate(chatId: sid)

                    // Finalize all message content
                    summaryService.reset()
                    self.streamState.setThinkingSummary(nil, chatId: sid)
                    self.streamState.setWebSearchSummary(nil, chatId: sid)
                    if !chat.messages.isEmpty, let lastIndex = chat.messages.indices.last {
                        chat.messages[lastIndex].content = finalSnapshot.responseContent
                        chat.messages[lastIndex].thoughts = finalSnapshot.thoughts
                        chat.messages[lastIndex].thinkingChunks = finalSnapshot.thinkingChunks
                        chat.messages[lastIndex].isThinking = false
                        chat.messages[lastIndex].generationTimeSeconds = finalSnapshot.generationTimeSeconds
                        chat.messages[lastIndex].thinkingDuration = finalSnapshot.generationTimeSeconds
                        chat.messages[lastIndex].webSearchBeforeThinking = finalSnapshot.webSearchBeforeThinking
                        chat.messages[lastIndex].contentChunks = finalSnapshot.contentChunks
                        chat.messages[lastIndex].segments = finalSnapshot.segments.isEmpty ? nil : finalSnapshot.segments
                        chat.messages[lastIndex].toolCalls = finalSnapshot.toolCalls
                        if !finalSnapshot.timelineBlocks.isEmpty {
                            chat.messages[lastIndex].timeline = finalSnapshot.timelineBlocks
                        }
                        chat.messages[lastIndex].webSearches = finalSnapshot.webSearches.isEmpty ? nil : finalSnapshot.webSearches
                        // Merge final collected sources into the aggregate webSearchState,
                        // promoting the same way.
                        if !finalSnapshot.collectedSources.isEmpty {
                            var searchState = chat.messages[lastIndex].webSearchState ?? WebSearchState(status: .searching)
                            searchState.sources = finalSnapshot.collectedSources
                            if searchState.status == .searching {
                                searchState.status = .completed
                            }
                            chat.messages[lastIndex].webSearchState = searchState
                        }
                        if !finalSnapshot.collectedAnnotations.isEmpty {
                            chat.messages[lastIndex].annotations = finalSnapshot.collectedAnnotations
                        }
                    }

                    // Apply finalized content to currentChat before ending the stream.
                    // The isLoadingChanged path in MessageTableView.updateUIView reads
                    // messages.last (from currentChat) to populate the wrapper. If the
                    // stream ends first, the wrapper captures stale throttled
                    // content. Title generation (async) then delays the real updateChat,
                    // and no subsequent updateUIView branch refreshes the wrapper — causing
                    // the first assistant response to appear truncated.
                    self.updateChat(chat)
                    if self.currentChat?.id == sid {
                        AccessibilityAnnouncer.announce(Constants.Accessibility.responseComplete)
                        HapticFeedback.trigger(.success)
                    }

                    return chat
                }

                // Generate title before save to avoid uploading placeholder title
                if var chat = finalizedChat, chat.needsGeneratedTitle && chat.messages.count >= 2 {
                    if let generated = await self.generateLLMTitle(from: chat.messages) {
                        chat.title = generated
                        chat.titleState = .generated
                        chat.locallyModified = true
                        chat.updatedAt = Date()
                        finalizedChat = chat
                        await MainActor.run {
                            Chat.triggerSuccessFeedback()
                        }
                    }
                }

                guard !Task.isCancelled else { return }

                // Save with the resolved title and trigger cloud backup
                await MainActor.run {
                    if let chat = finalizedChat {
                        self.updateChat(chat)
                        self.endStreamingAndBackup(chatId: chat.id)
                    }
                    self.finishStreamState(chatId: streamChatId)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    return
                }

                #if DEBUG
                print("[Chat] generateResponse error: \(type(of: error)) — \(error)")
                print("[Chat] isAuthError=\(ChatViewModel.isAuthenticationError(error)), isRequestError=\(self.isRequestError(error)), isRateLimitError=\(Self.isRateLimitError(error))")
                #endif

                // Check if this is a 401 auth error and we haven't retried yet
                let shouldRetry = await MainActor.run {
                    if !hasRetriedWithFreshKey && ChatViewModel.isAuthenticationError(error) {
                        #if DEBUG
                        print("[Chat] Will retry with fresh key")
                        #endif
                        return true
                    }
                    return false
                }

                if shouldRetry {
                    hasRetriedWithFreshKey = true
                    // The token is reminted by acquireTokenForSend at the top of
                    // the retry pass (forceRefresh), so no separate refresh here.
                    if await MainActor.run(body: { self.client != nil }) {
                        continue retryLoop
                    }
                }

                // Handle error
                await MainActor.run {
                    if self.currentChat?.id == streamChatId {
                        AccessibilityAnnouncer.announce(Constants.Accessibility.responseFailed)
                        HapticFeedback.trigger(.error)
                    }
                    self.streamState.setThinkingSummary(nil, chatId: streamChatId)
                    self.streamState.setWebSearchSummary(nil, chatId: streamChatId)

                    // Mark the chat as no longer having an active stream
                    // Look up by streamChatId, not self.currentChat, in case user navigated away
                    let sid = streamChatId
                    if let location = self.findChatLocation(sid) {
                        var chat = self.chat(at: location)
                        chat.hasActiveStream = false

                        // Force any pending stream updates to save immediately
                        self.flushPendingStreamUpdate(chatId: sid)

                        self.updateChat(chat)  // Final update without throttling

                        self.endStreamingAndBackup(chatId: chat.id)
                    } else {
                        self.streamingTracker.endStreaming(sid)
                    }

                    if let location = self.findChatLocation(sid) {
                        var chat = self.chat(at: location)
                        if !chat.messages.isEmpty {
                            let lastIndex = chat.messages.count - 1

                            // Format a more user-friendly error message based on the error type
                            let userFriendlyError = formatUserFriendlyError(error)

                            // Set the stream error - the ErrorMessageView will display it nicely
                            // Keep any partial content that was received
                            // The hourly cap is surfaced deterministically at
                            // token acquisition (the inference path never checks
                            // it), so the only signal here is that typed error —
                            // no inference-failure heuristic.
                            let hitHourlyCap: Bool
                            if case SessionTokenError.hourlyLimitReached = error {
                                hitHourlyCap = true
                            } else {
                                hitHourlyCap = false
                            }
                            chat.messages[lastIndex].isRequestError = self.isRequestError(error)
                            chat.messages[lastIndex].streamError = userFriendlyError
                            chat.messages[lastIndex].isRateLimitError = Self.isRateLimitError(error) || hitHourlyCap
                            chat.messages[lastIndex].isHourlyLimitError = hitHourlyCap
                            chat.messages[lastIndex].isConnectionError = Self.isConnectionError(error)

                            self.updateChat(chat)
                        }
                    }
                    self.finishStreamState(chatId: sid)
                }
            }

            // Refresh rate limit from the server after each request completes (success or error)
            SessionTokenManager.shared.refreshRateLimit()
        }
        streamTasks[streamChatId] = streamTask
    }
    
    /// Applies one throttled streaming snapshot to the streaming chat's last
    /// message. Snapshots are immutable values produced by the stream task's
    /// processor, so this never reads live parsing state.
    private func applyStreamSnapshot(_ snapshot: StreamingResponseProcessor.Snapshot, streamChatId: String) {
        guard let location = findChatLocation(streamChatId) else { return }
        var chat = chat(at: location)
        guard
              chat.hasActiveStream,
              !chat.messages.isEmpty,
              let lastIndex = chat.messages.indices.last else {
            return
        }

        chat.messages[lastIndex].content = snapshot.responseContent
        chat.messages[lastIndex].thoughts = snapshot.thoughts
        chat.messages[lastIndex].thinkingChunks = snapshot.thinkingChunks
        chat.messages[lastIndex].isThinking = snapshot.isThinking
        chat.messages[lastIndex].generationTimeSeconds = snapshot.generationTimeSeconds
        chat.messages[lastIndex].contentChunks = snapshot.contentChunks
        chat.messages[lastIndex].segments = snapshot.segments.isEmpty ? nil : snapshot.segments
        chat.messages[lastIndex].webSearches = snapshot.webSearches.isEmpty ? nil : snapshot.webSearches
        chat.messages[lastIndex].toolCalls = snapshot.toolCalls
        if !snapshot.timelineBlocks.isEmpty {
            chat.messages[lastIndex].timeline = snapshot.timelineBlocks
        }

        // Merge collected sources into the message's current webSearchState.
        if !snapshot.collectedSources.isEmpty {
            var searchState = chat.messages[lastIndex].webSearchState ?? WebSearchState(status: .searching)
            searchState.sources = snapshot.collectedSources
            chat.messages[lastIndex].webSearchState = searchState
        }
        if !snapshot.collectedAnnotations.isEmpty {
            chat.messages[lastIndex].annotations = snapshot.collectedAnnotations
        }

        self.updateChat(chat, throttleForStreaming: true)
    }

    /// Formats a user-friendly error message from the caught error
    private func formatUserFriendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        
        // Network connectivity issues
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, 
                 NSURLErrorDataNotAllowed:
                return "The Internet connection appears to be offline."
            case NSURLErrorNetworkConnectionLost:
                return "Network connection was lost. The response may be incomplete."
            case NSURLErrorTimedOut:
                return "Request timed out. Please try again."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Unable to connect to the server. Please try again later."
            default:
                return "Network error. Please check your connection and try again."
            }
        }
        
        // Authentication issues
        if nsError.domain == "TinfoilChat" && nsError.code == 401 {
            return "Authentication error. Please sign in again."
        }
        
        // HTTP status errors from the OpenAI SDK. Handle every code here so
        // the raw enum dump (including the NSHTTPURLResponse description)
        // never reaches the UI.
        if case OpenAIError.statusError(_, let statusCode) = error {
            switch statusCode {
            case 401:
                return "Authentication error. Please sign in again."
            case 429:
                return "You've reached your daily limit of free requests. Your limit will reset tomorrow, or you can upgrade to Premium for unlimited access."
            case 500...599:
                return "The service is having trouble right now. Please try again in a moment, or switch to a different model."
            default:
                return "The model couldn't process this request. Please try again, or start a new chat if the problem persists."
            }
        }

        // Server issues
        if let httpResponse = nsError.userInfo[NSUnderlyingErrorKey] as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 500...599:
                return "Server error. Our team has been notified and is working on it."
            case 429:
                return "You've reached your daily limit of free requests. Your limit will reset tomorrow, or you can upgrade to Premium for unlimited access."
            default:
                break
            }
        }

        // Map raw backend/SDK error text to a human-readable explanation,
        // mirroring the webapp's `explainError`.
        if let explained = Self.explainRawError(error.localizedDescription) {
            return explained
        }

        // Default error message if nothing specific matches
        return "Please try again. If the problem persists, contact support."
    }

    /// Maps raw error text to a friendly explanation. Returns nil when no
    /// known pattern matches. Mirrors the webapp's `explainError` patterns.
    static func explainRawError(_ rawMessage: String) -> String? {
        let lower = rawMessage.lowercased()

        if lower.contains("context deadline exceeded") ||
            lower.contains("client.timeout") ||
            lower.contains("timed out") ||
            lower.contains("timeout") {
            return "The model took too long to respond. This is usually a temporary problem on our side. Please try again in a moment."
        }

        if lower.contains("context length") ||
            lower.contains("context window") ||
            lower.contains("maximum context") ||
            lower.contains("too many tokens") ||
            lower.contains("token limit") ||
            lower.contains("prompt length") ||
            lower.contains("max_model_len") ||
            lower.contains("input is too long") {
            return "This conversation is too long for the model. Remove an attachment, shorten your message, or switch to a model with a larger context window."
        }

        // Secure-channel failures (EHBP) happen when the inference router is
        // unreachable and a proxy answers without the encryption headers.
        if lower.contains("ehbp") ||
            lower.contains("missing header") ||
            lower.contains("decryption failed") ||
            lower.contains("invalid response") ||
            lower.contains("overloaded") ||
            lower.contains("capacity") ||
            lower.contains("service unavailable") ||
            lower.contains("bad gateway") ||
            lower.contains("internal server error") ||
            lower.range(of: #"\b5\d\d\b"#, options: .regularExpression) != nil {
            return "The service is having trouble right now. Please try again in a moment, or switch to a different model."
        }

        if lower.contains("network") ||
            lower.contains("connection") ||
            lower.contains("offline") {
            return "Connection problem. Check your internet connection and try again."
        }

        return nil
    }

    /// Checks if an error is a connectivity failure.
    static func isConnectionError(_ error: Error) -> Bool {
        URLErrorClassifier.isConnectivityFailure(error)
    }

    /// Checks if an error indicates the user has hit their rate limit
    static func isRateLimitError(_ error: Error) -> Bool {
        if case OpenAIError.statusError(_, let statusCode) = error, statusCode == 429 {
            return true
        }
        // Non-streaming path: the SDK decodes the response body into
        // APIErrorResponse, which carries the structured code field.
        if let apiError = error as? APIErrorResponse {
            return apiError.error.type == Constants.API.ErrorType.rateLimit
                || apiError.error.code == Constants.API.ErrorCode.insufficientQuota
                || apiError.error.code == Constants.API.ErrorCode.rateLimitExceeded
        }
        return false
    }

    /// Checks if an error is a client request error (4xx, excluding 401 which is handled by retry)
    private func isRequestError(_ error: Error) -> Bool {
        if case OpenAIError.statusError(_, let statusCode) = error,
           (400...499).contains(statusCode), statusCode != 401 {
            return true
        }
        if let apiError = error as? APIErrorResponse,
           apiError.error.code != Constants.API.ErrorCode.invalidAPIKey {
            return true
        }
        return false
    }

    /// Checks if an error is an authentication error (401)
    static func isAuthenticationError(_ error: Error) -> Bool {
        // Streaming path: the SDK checks the HTTP status code before reading the body
        // and throws OpenAIError.statusError with the original status code
        if case OpenAIError.statusError(_, let statusCode) = error,
           statusCode == 401 {
            return true
        }

        // Non-streaming path: the SDK decodes the response body into APIErrorResponse
        // which contains the error code from our controlplane/shim
        if let apiError = error as? APIErrorResponse,
           apiError.error.code == Constants.API.ErrorCode.invalidAPIKey {
            return true
        }

        return false
    }

    /// Mints a fresh session token in place for a retry. The attested client
    /// reads the bearer through its provider, so the token can rotate without
    /// rebuilding the client or re-running enclave verification.
    private func refreshSessionTokenForRetry() async {
        _ = await SessionTokenManager.shared.fetchFreshSessionToken()
    }

    /// Cancels the current message generation
    func cancelGeneration() {
        guard let chatId = currentChat?.id else { return }
        _ = cancelGeneration(chatId: chatId, announce: true)
        self.showVerifierSheet = false
    }

    @discardableResult
    private func cancelGeneration(
        chatId: String,
        announce: Bool
    ) -> Task<Void, Never>? {
        guard streamState.isStreaming(chatId: chatId) else { return nil }

        let streamTask = streamTasks[chatId]
        streamTask?.cancel()
        flushPendingStreamUpdate(chatId: chatId)
        if let location = findChatLocation(chatId) {
            var chat = chat(at: location)
            chat.hasActiveStream = false
            updateChat(chat)
            streamingTracker.endStreaming(chat.id)
        } else {
            streamingTracker.endStreaming(chatId)
        }

        finishStreamState(chatId: chatId)
        if announce {
            AccessibilityAnnouncer.announce(Constants.Accessibility.generationStopped)
        }
        return streamTask
    }

    private func cancelAllGenerations() -> [Task<Void, Never>] {
        Array(streamState.activeChatIds).compactMap { chatId in
            cancelGeneration(
                chatId: chatId,
                announce: false
            )
        }
    }

    private func drainStreamTasks(_ tasks: [Task<Void, Never>]) async {
        for task in tasks {
            await task.value
        }
    }

    private func flushPendingStreamUpdate(chatId: String) {
        streamUpdateTimers.removeValue(forKey: chatId)?.invalidate()
        if let pending = pendingStreamUpdates.removeValue(forKey: chatId),
           hasChatAccess {
            saveChat(pending)
        }
    }

    private func finishStreamState(chatId: String) {
        streamUpdateTimers.removeValue(forKey: chatId)?.invalidate()
        pendingStreamUpdates.removeValue(forKey: chatId)
        streamTasks.removeValue(forKey: chatId)
        thinkingSummaryServices.removeValue(forKey: chatId)?.reset()
        streamState.finish(chatId: chatId)
    }

    /// Regenerates the last assistant response by removing it and resending the last user message
    func regenerateLastResponse() {
        guard let chat = currentChat,
              !isLoading else {
            return
        }

        // Find the last user message
        guard let lastUserMessageIndex = chat.messages.lastIndex(where: { $0.role == .user }) else {
            return
        }

        // Remove only messages AFTER the user message (keep the user message)
        var updatedChat = chat
        updatedChat.messages = Array(chat.messages.prefix(lastUserMessageIndex + 1))
        updatedChat.locallyModified = true
        updatedChat.updatedAt = Date()

        // Update both currentChat and the appropriate array
        currentChat = updatedChat
        replaceChat(updatedChat)

        // Save and generate response (without adding user message again)
        saveChat(updatedChat)
        isScrollInteractionActive = false
        scrollToUserMessageTrigger = UUID()
        generateResponse()
    }

    /// Edits a user message at a specific index, removing all messages after it and resending with new content
    /// - Parameters:
    ///   - messageIndex: The index of the user message to edit
    ///   - newContent: The new content for the message
    func editMessage(at messageIndex: Int, newContent: String) {
        guard let chat = currentChat,
              !isLoading,
              messageIndex >= 0,
              messageIndex < chat.messages.count,
              chat.messages[messageIndex].role == .user else {
            return
        }

        let trimmedContent = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        // Truncate to remove the edited message and all messages after it
        var updatedChat = chat
        updatedChat.messages = Array(chat.messages.prefix(messageIndex))
        updatedChat.locallyModified = true
        updatedChat.updatedAt = Date()

        // Update both currentChat and the appropriate array
        currentChat = updatedChat
        replaceChat(updatedChat)

        saveChat(updatedChat)

        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        let userMessage = Message(role: .user, content: trimmedContent)
        addMessage(userMessage)

        generateResponse()
    }

    /// Regenerates the response for a user message at a specific index
    /// - Parameter messageIndex: The index of the user message to regenerate from
    func regenerateMessage(at messageIndex: Int) {
        guard let chat = currentChat,
              !isLoading,
              messageIndex >= 0,
              messageIndex < chat.messages.count,
              chat.messages[messageIndex].role == .user else {
            return
        }

        // Keep the user message, only remove messages after it (assistant responses)
        var updatedChat = chat
        updatedChat.messages = Array(chat.messages.prefix(messageIndex + 1))
        updatedChat.locallyModified = true
        updatedChat.updatedAt = Date()

        currentChat = updatedChat
        replaceChat(updatedChat)

        isScrollInteractionActive = false
        scrollToUserMessageTrigger = UUID()

        saveChat(updatedChat)
        generateResponse()
    }

    /// Shows the verifier sheet with current verification state
    func showVerifier() {
        verifierView = VerifierView()
        showVerifierSheet = true
    }
    
    /// Dismisses the verifier sheet
    func dismissVerifier() {
        self.showVerifierSheet = false
        self.verifierView = nil
    }

    /// Resume the sign-in flow after the user completes manual key setup via CloudSyncOnboardingView.
    func resumeAfterManualKeySetup() {
        Task {
            do {
                let key = try await EncryptionService.shared.initialize()
                self.encryptionKey = key

                await self.passkeyManager.checkPasskeyStateForExistingKey()

                await retryDecryptionAndReloadChats()

                if SettingsManager.shared.isCloudSyncEnabled {
                    await initializeCloudSync()
                    await ProfileManager.shared.performFullSync()
                }

                await MainActor.run {
                    let activeList = SettingsManager.shared.isCloudSyncEnabled ? self.chats : self.localChats
                    if activeList.isEmpty {
                        self.createNewChat()
                    } else {
                        self.ensureBlankChatAtTop()
                    }
                }
            } catch {
                await MainActor.run {
                    self.showEncryptionSetup = true
                }
            }
        }
    }
    
    // MARK: - Private Methods

    private func retryDecryptionAndReloadChats() async {
        let decryptedCount = await cloudSync.retryDecryptionWithNewKey(onProgress: nil)
        guard decryptedCount > 0 else { return }

        let result = await loadFirstPageOfChats(userId: self.currentUserId, filter: \.isCloudDisplayable)
        await MainActor.run {
            self.chats = result.chats
            if let currentId = self.currentChat?.id,
               let refreshed = result.chats.first(where: { $0.id == currentId }) {
                self.currentChat = refreshed
            }
            normalizeChatsArray()
        }
    }

    private func endStreamingAndBackup(chatId: String) {
        guard authManager?.isAuthenticated == true else { return }

        streamingTracker.endStreaming(chatId)

        guard let location = findChatLocation(chatId) else {
            return
        }
        let latestChat = chat(at: location)
        saveChat(latestChat)

        let saveTask = pendingSaveTask
        let isLocal = location.isLocal
        Task { @MainActor in
            await saveTask?.value
            if SettingsManager.shared.isCloudSyncEnabled && !latestChat.isLocalOnly {
                await self.cloudSync.backupChat(latestChat.id)
            }

            if let syncedChat = await Chat.loadChat(chatId: latestChat.id, userId: self.currentUserId) {
                if isLocal {
                    if let idx = self.localChats.firstIndex(where: { $0.id == latestChat.id }) {
                        self.localChats[idx] = syncedChat
                    }
                } else {
                    if let idx = self.chats.firstIndex(where: { $0.id == latestChat.id }) {
                        self.chats[idx] = syncedChat
                    }
                }
                if self.currentChat?.id == latestChat.id {
                    self.currentChat = syncedChat
                }
            }
        }
    }

    /// Normalizes the chats array to ensure exactly one blank chat at position 0
    /// This is the single source of truth for chat array structure:
    /// 1. Removes ALL blank chats (deduplicates)
    /// 2. Deduplicates by chat ID (preserves order)
    /// 3. Adds exactly ONE blank chat at position 0 if user has chat access
    ///
    /// Note: This does NOT sort. Caller should sort chats before calling this if needed.
    private func normalizeChatsArray() {
        chats = normalizeAndDedup(chats, isLocal: false)
    }

    /// Normalizes the localChats array: deduplicates and ensures one blank chat at top
    private func normalizeLocalChatsArray() {
        localChats = normalizeAndDedup(localChats, isLocal: true)
    }

    /// Shared normalization: removes duplicates, ensures one blank chat at top,
    /// and updates currentChat if it was pointing to a stale blank.
    private func normalizeAndDedup(_ source: [Chat], isLocal: Bool) -> [Chat] {
        let wasCurrentChatBlank = currentChat?.isBlankChat == true
            && currentChat?.isLocalOnly == isLocal

        // Remove all blank chats, then deduplicate by ID (keep first occurrence)
        var seenIds = Set<String>()
        var result = source.filter { !$0.isBlankChat }.filter { chat in
            if seenIds.contains(chat.id) { return false }
            seenIds.insert(chat.id)
            return true
        }

        // Add exactly one blank chat at position 0 if user has chat access
        if hasChatAccess {
            let webSearchEnabled = wasCurrentChatBlank
                ? currentChat?.webSearchEnabled
                : nil
            let blankChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId,
                isLocalOnly: isLocal,
                webSearchEnabled: webSearchEnabled
            )
            result.insert(blankChat, at: 0)

            if wasCurrentChatBlank {
                currentChat = blankChat
            }
        }

        return result
    }

    /// Ensures there's always a blank chat at the top of the list
    /// This now simply calls normalizeChatsArray() for consistency
    private func ensureBlankChatAtTop() {
        if SettingsManager.shared.isCloudSyncEnabled {
            normalizeChatsArray()
            normalizeLocalChatsArray()
        } else {
            normalizeLocalChatsArray()
        }
    }

    /// Persist the collapse state for a message's thinking box
    func setThoughtsCollapsed(for messageId: String, collapsed: Bool) {
        guard var chat = currentChat,
              let messageIndex = chat.messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        if chat.messages[messageIndex].isCollapsed == collapsed {
            return
        }

        chat.messages[messageIndex].isCollapsed = collapsed
        // During streaming, use throttled update to avoid disk I/O interfering with the stream
        updateChat(chat, throttleForStreaming: chat.hasActiveStream)
    }

    /// Adds a message to the current chat
    private func addMessage(_ message: Message) {
        guard var chat = currentChat else {
            return
        }
        
        
        // Add directly to the full message list
        chat.messages.append(message)
        
        // Mark as locally modified to prevent sync from overwriting
        chat.locallyModified = true
        chat.updatedAt = Date()
        
        updateChat(chat) // Saves the full list
    }
    
    /// Updates a chat in the chats array AND saves
    private func updateChat(_ chat: Chat, throttleForStreaming: Bool = false) {
        var updatedChat = chat
        
        // If the chat has an active stream or is being actively modified, ensure it's marked as locally modified
        // This prevents sync from overwriting it while messages are being sent
        if chat.hasActiveStream {
            updatedChat.locallyModified = true
            updatedChat.updatedAt = Date()
        }
        
        replaceChat(updatedChat)

        // Update currentChat directly ONLY IF it's the one being updated
        if currentChat?.id == chat.id {
            currentChat = updatedChat
        }

        // During streaming, batch saves to reduce disk I/O
        if throttleForStreaming {
            // Store pending update
            pendingStreamUpdates[updatedChat.id] = updatedChat

            // Cancel existing timer and create new one
            streamUpdateTimers[updatedChat.id]?.invalidate()
            streamUpdateTimers[updatedChat.id] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.flushPendingStreamUpdate(chatId: updatedChat.id)
                }
            }
        } else {
            // Save immediately for non-streaming updates
            if hasChatAccess {
                saveChat(updatedChat)
            }
        }
    }
    
    /// Saves a single chat to per-chat file storage and triggers cloud backup
    private func saveChat(_ chat: Chat, shouldBackup: Bool = true) {
        guard !chat.isTemporary else { return }
        guard hasChatAccess else { return }
        guard !chat.messages.isEmpty || chat.decryptionFailed else { return }

        let userId = currentUserId
        let previous = pendingSaveTask
        pendingSaveTask = Task.detached(priority: .utility) {
            await previous?.value
            await Chat.saveChat(chat, userId: userId)
        }

        // Trigger cloud backup if cloud sync is enabled, the chat is not local-only,
        // has messages, and no active stream.
        if shouldBackup && SettingsManager.shared.isCloudSyncEnabled && !chat.isLocalOnly && !chat.messages.isEmpty && !chat.hasActiveStream {
            let saveTask = pendingSaveTask
            Task {
                await saveTask?.value
                await cloudSync.backupChat(chat.id)
            }
        }
    }

    private func drainPendingSaves() async {
        await pendingSaveTask?.value
    }
    
    
    // MARK: - Model Management
    
    /// Changes the current model and re-initializes the Tinfoil client
    func changeModel(to modelType: ModelType, shouldUpdateChat: Bool = true) {
        // Only proceed if the model is actually changing
        guard modelType != currentModel else { return }
        
        // Update model settings
        self.currentModel = modelType
        // This will trigger the didSet in AppConfig which persists to UserDefaults
        AppConfig.shared.currentModel = modelType
        
        // Update the current chat's model if requested
        if shouldUpdateChat, var chat = currentChat {
            chat.modelType = modelType
            updateChat(chat)
        }
    }
    
    // MARK: - Authentication & Model Access
    
    /// Updates the current model if needed based on auth status changes
    func updateModelBasedOnAuthStatus(isAuthenticated: Bool, hasActiveSubscription: Bool) {
        // Only reinitialize client if auth state actually changed (not just subscription)
        let authStateChanged = lastKnownAuthState != isAuthenticated
        lastKnownAuthState = isAuthenticated

        if authStateChanged {
            // Clear cached session token and reinitialize client only when auth changes
            SessionTokenManager.shared.clearSessionToken()
            setupTinfoilClient()
        }

        // If current model is no longer selectable, switch to first available model
        let selectableModels = AppConfig.shared.selectableModels
        if !selectableModels.contains(where: { $0.id == currentModel.id }),
           let firstModel = AppConfig.shared.filteredModelTypes().first {
            changeModel(to: firstModel)
        }
        
        
        // If user upgraded to premium, load saved chats if any
        if isAuthenticated && hasActiveSubscription && chats.count <= 1 {
            Task {
                let result = await loadFirstPageOfChats(userId: currentUserId, filter: \.isCloudDisplayable)
                guard !result.chats.isEmpty else { return }
                let previouslySelectedId = self.currentChat?.id
                self.chats = result.chats

                // Preserve existing selection when possible so we don't jump to a blank chat
                if let chatId = previouslySelectedId,
                   let location = self.findChatLocation(chatId) {
                            self.currentChat = self.chat(at: location)
                        } else if self.currentChat == nil {
                            self.currentChat = self.chats.first
                }

                self.ensureBlankChatAtTop()
            }
        }
    }
    
    /// Handle sign-out by clearing current chats but preserving them in storage
    func handleSignOut() async {
        // Allow a new sign-in flow after sign-out
        isSignInInProgress = false
        hasPerformedInitialSync = false
        let canceledStreamTasks = cancelAllGenerations()
        await drainStreamTasks(canceledStreamTasks)

        // Stop auto-sync timer when signing out
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil

        // Save all local chats with content to disk before clearing in-memory state.
        // This is called while isAuthenticated is still true (see clearAuthState ordering)
        // so that hasChatAccess/currentUserId are available for the save.
        if hasChatAccess {
            for chat in localChats where !chat.messages.isEmpty {
                saveChat(chat, shouldBackup: false)
            }
            if let chat = currentChat, !chat.messages.isEmpty {
                saveChat(chat, shouldBackup: false)
            }
        }

        // Clear sync caches so stale state doesn't leak into the next session
        await cloudSync.clearSyncStatus()
        DeletedChatsTracker.shared.clear()
        CloudKeyAuthorizationStore.shared.clearAuthorization(userId: currentUserId)

        // Reset to the default model when signing out
        let allModels = AppConfig.shared.filteredModelTypes()
        if let defaultModel = allModels.first {
            currentModel = defaultModel
            AppConfig.shared.currentModel = defaultModel
        }

        // Reset pagination state when signing out
        paginationToken = nil
        hasMoreChats = false
        isPaginationActive = false
        hasLoadedInitialPage = false
        hasAttemptedLoadMore = false

        // Reset passkey state
        passkeyManager.reset()

        // Clear cloud chats and create a new empty one with the free model.
        // On-disk local chats are wiped immediately after this by clearAuthState's
        // full sign-out cleanup, so no content persists across accounts.
        chats = []
        localChats = []
        activeStorageTab = .cloud
        let newChat = Chat.create(modelType: currentModel)
        currentChat = newChat
        chats = [newChat]

    }
    
    /// Clear all local chats and reset to fresh state
    func clearAllChatsFromDevice() async {
        let canceledStreamTasks = cancelAllGenerations()

        // Clear all chats from memory
        chats.removeAll()
        localChats.removeAll()
        currentChat = nil
        
        // Clear from file storage (both local and cloud stores)
        let userId = currentUserId
        await drainStreamTasks(canceledStreamTasks)
        await drainPendingSaves()
        await Chat.deleteAllChatsFromStorage(userId: userId)
        
        // Reset sync state
        lastSyncDate = nil
        syncErrors = []
        isSyncing = false
        SyncHealthStore.shared.reset()
        
        // Reset pagination state
        paginationToken = nil
        hasMoreChats = false
        isPaginationActive = false
        hasLoadedInitialPage = false
        hasAttemptedLoadMore = false
        
        // Clear encryption key reference
        encryptionKey = nil
    }

    /// Erase on-disk chats for the signed-out user during sign-out cleanup.
    /// The in-memory blank chat created by handleSignOut is left intact so the
    /// signed-out session still has a usable chat. Must run before the auth
    /// manager clears its authenticated state so currentUserId still resolves.
    func wipeLocalChatsForSignOut() async {
        // Drain the queued disk saves first; the queue is chained, so
        // awaiting the latest task flushes every earlier one. Otherwise a
        // detached save kicked off by handleSignOut could land after the
        // wipe and resurrect the signed-out user's chat files.
        await drainPendingSaves()
        await Chat.deleteAllChatsFromStorage(userId: currentUserId)
    }

    /// Clear a persisted passkey-recovery skip and re-open recovery.
    /// Backs the Settings and sidebar "unlock cloud sync" affordances.
    /// Routes the manual setup / recovery outcomes to the onboarding
    /// sheet, matching the sign-in flow.
    func reattemptPasskeyRecovery() async {
        let result = await passkeyManager.reenableRecoveryPrompt()
        switch result {
        case .manualSetupRequired:
            cloudSyncOnboardingMode = .setup
            showCloudSyncOnboarding = true
        case .manualRecoveryRequired:
            cloudSyncOnboardingMode = .recovery
            showCloudSyncOnboarding = true
        case .success:
            // A silent re-unlock applied the key but, unlike the prompt-driven
            // recovery paths, fires no completion callback. Resume loading and
            // sync so the now-decryptable chats refresh immediately instead of
            // waiting for a later sign-in or manual refresh.
            handleSignIn()
        default:
            break
        }
    }

    /// Handle sign-in by loading user's saved chats and triggering sync
    func handleSignIn() {
        #if DEBUG
        print("handleSignIn called")
        #endif

        // Wire up passkey recovery callback
        passkeyManager.onRecoveryComplete = { [weak self] in
            self?.handleSignIn()
        }

        // Wire up periodic passkey sync callback — retry decryption when
        // another device updates the key bundle
        passkeyManager.onKeyRefreshedFromBackup = { [weak self] in
            Task { @MainActor in
                await self?.retryDecryptionWithNewKey()
            }
        }

        // Prevent duplicate sign-in flows
        guard !isSignInInProgress else {
            #if DEBUG
            print("handleSignIn: Already in progress, skipping")
            #endif
            return
        }

        #if DEBUG
        print("handleSignIn: hasChatAccess=\(hasChatAccess), userId=\(currentUserId ?? "nil")")
        #endif
        
        if hasChatAccess, let userId = currentUserId {
            isSignInInProgress = true
            #if DEBUG
            print("handleSignIn: Starting sign-in flow for user \(userId)")
            #endif
            
            // Restore pagination state immediately for better UX on cold start
            loadPersistedPaginationState()
            
            // Check if we have any anonymous chats to migrate
            let anonymousChats = (chats + localChats).filter { chat in
                chat.userId == nil && !chat.messages.isEmpty
            }
            
            if !anonymousChats.isEmpty {
                #if DEBUG
                print("Found \(anonymousChats.count) anonymous chats to migrate")
                #endif
                // Migrate anonymous chats to the current user
                for var chat in anonymousChats {
                    chat.userId = userId
                    chat.locallyModified = true
                    chat.syncVersion = 0  // Reset sync version to force upload
                    replaceChat(chat)
                    saveChat(chat)
                }
                
                // Mark that we have anonymous chats that need to be synced after encryption setup
                Task { @MainActor in
                    self.hasAnonymousChatsToSync = true
                }
            }
            
            // Start auto-sync timer now that user is authenticated
            // (This also handles the case where someone signs in after app launch)
            setupAutoSyncTimer()

            // One-shot legacy cleanup for users who sign in after launch;
            // the launch-time pass only covers an already-signed-in user.
            // Flag-gated per user, so re-running is cheap.
            Task.detached(priority: .background) {
                await LegacyChatEviction.runIfNeeded(userId: userId)
            }
            
            // Check if we need to set up encryption first
            // IMPORTANT: Do NOT auto-generate a key here; allow UI to prompt the user
            Task {
                do {
                    // Always load local chats first — they use the device key,
                    // not the cloud encryption key, so they're available regardless
                    // of cloud sync setup state.
                    let allLocal = await loadAllLocalChats(userId: self.currentUserId)
                    await MainActor.run {
                        self.localChats = allLocal
                        normalizeLocalChatsArray()
                        if self.currentChat == nil, let first = self.localChats.first {
                            self.currentChat = first
                        }
                        // Auto-enable local-only mode when local chats with messages exist,
                        // but only if the user has never explicitly set the preference
                        let hasNonEmptyLocalChats = self.localChats.contains { !$0.messages.isEmpty }
                        let userHasSetPreference = UserDefaults.standard.object(forKey: Constants.StorageKeys.Settings.localOnlyModeEnabled) != nil
                        if hasNonEmptyLocalChats && !userHasSetPreference {
                            SettingsManager.shared.isLocalOnlyModeEnabled = true
                        }
                    }

                    // If no cloud key exists, try passkey recovery before falling back
                    if !EncryptionService.shared.hasEncryptionKey() {
                        let passkeyResult = await self.passkeyManager.attemptPasskeyKeyRecovery()
                        switch passkeyResult {
                        case .success, .newUserSetupDone:
                            break
                        case .manualSetupRequired:
                            await MainActor.run {
                                self.cloudSyncOnboardingMode = .setup
                                self.showCloudSyncOnboarding = true
                                self.isSignInInProgress = false
                            }
                            return
                        case .manualRecoveryRequired:
                            await MainActor.run {
                                self.cloudSyncOnboardingMode = .recovery
                                self.showCloudSyncOnboarding = true
                                self.isSignInInProgress = false
                            }
                            return
                        case .recoveryFailed:
                            await MainActor.run {
                                self.isSignInInProgress = false
                            }
                            return
                        }
                    }

                    // Initialize encryption - this will load existing key from keychain
                    let key = try await EncryptionService.shared.initialize()
                    self.encryptionKey = key

                    // Ensure the current key is authorized for cloud writes.
                    // Existing users upgrading may have a valid key but no
                    // authorization record yet.
                    if !CloudKeyAuthorizationStore.shared.hasAuthorizedCurrentPrimaryKey(userId: userId) {
                        let validation = await CloudKeyPreflightValidator.shared.validateCurrentPrimaryKey()
                        if validation.canWrite {
                            _ = CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: .validated, userId: userId)
                        }
                    }

                    // A local key that mismatches the enclave's registered
                    // key can never sync or migrate. Converge silently via
                    // passkey when possible; otherwise prompt the user to
                    // recover so this stale device enters v2.
                    if SettingsManager.shared.isCloudSyncEnabled,
                       await self.passkeyManager.resolveKeyMismatchAtLaunch() == .manualRecoveryRequired {
                        await MainActor.run {
                            self.cloudSyncOnboardingMode = .recovery
                            self.showCloudSyncOnboarding = true
                        }
                    }

                    // Check passkey state for users who already have keys
                    await self.passkeyManager.checkPasskeyStateForExistingKey()

                    // Retry decryption for any previously failed chats now that key is loaded
                    let decryptedCount = await cloudSync.retryDecryptionWithNewKey(onProgress: nil)
                    if decryptedCount > 0 {
                        let result = await loadFirstPageOfChats(userId: self.currentUserId, filter: \.isCloudDisplayable)
                        await MainActor.run {
                            self.chats = result.chats
                            // Refresh currentChat to show decrypted content
                            if let currentId = self.currentChat?.id,
                               let refreshed = result.chats.first(where: { $0.id == currentId }) {
                                self.currentChat = refreshed
                            }
                            normalizeChatsArray()
                        }
                    }

                    // If we have anonymous chats to sync, force re-encryption with proper key
                    if self.hasAnonymousChatsToSync {
                        // Force all cloud chats to be marked for sync
                        if let userId = self.currentUserId {
                            let cloudChats = (try? await EncryptedFileStorage.cloud.loadAllChats(userId: userId)) ?? []
                            for var chat in cloudChats {
                                chat.locallyModified = true
                                chat.syncVersion = 0
                                try? await EncryptedFileStorage.cloud.saveChat(chat, userId: userId)
                            }
                        }
                        self.hasAnonymousChatsToSync = false
                    }

                    // Local chats were already loaded above the early return.

                    // Only proceed with cloud sync if cloud sync is enabled
                    if SettingsManager.shared.isCloudSyncEnabled {
                        await initializeCloudSync()

                        // Restore persisted tab preference now that cloud chats are loaded
                        if let savedTab = UserDefaults.standard.string(forKey: Constants.StorageKeys.Settings.cloudSyncActiveTab),
                           let tab = ChatStorageTab(rawValue: savedTab) {
                            await MainActor.run {
                                self.activeStorageTab = tab
                            }
                        }

                        // Sync user profile settings
                        await ProfileManager.shared.performFullSync()
                    } else {
                        await MainActor.run {
                            self.chats = []
                            self.hasMoreChats = false
                            self.activeStorageTab = .local
                        }
                    }
                    
                    // Update last sync date
                    await MainActor.run {
                        self.lastSyncDate = Date()
                    }
                    
                    // After sync completes, ensure we have proper chat setup
                    await MainActor.run {
                        let activeList = SettingsManager.shared.isCloudSyncEnabled ? self.chats : self.localChats
                        if activeList.isEmpty {
                            self.createNewChat()
                        } else {
                            self.ensureBlankChatAtTop()
                        }
                        self.isSignInInProgress = false
                    }
                } catch {
                    // If key initialization fails, fall back to showing setup modal
                    await MainActor.run {
                        self.isFirstTimeUser = true
                        self.showEncryptionSetup = true
                        self.isSignInInProgress = false
                    }
                }
            }
        } else {
            // User doesn't have chat access, reset flag
            isSignInInProgress = false
        }
    }
    
    // MARK: - Cloud Sync Methods

    /// Permanently deletes every chat, mirroring the webapp: the cloud
    /// bulk-delete runs first so a failure leaves local state untouched and
    /// the user can retry without partial-deletion side effects.
    @MainActor
    func deleteAllChats() async throws {
        let localIds = chats.map(\.id) + localChats.map(\.id)

        // When the cloud backup is in play (key present, or sync enabled but
        // the key is missing) this must succeed or throw: skipping it would
        // report success while encrypted chats survive on the server. Only a
        // signed-in account that never set up cloud sync gets a local-only
        // wipe.
        let isAuthenticated = authManager?.isAuthenticated == true
        let hasKey = EncryptionService.shared.hasEncryptionKey()
        if isAuthenticated && (hasKey || SettingsManager.shared.isCloudSyncEnabled) {
            try await cloudSync.deleteAllFromCloud()
        }

        // Tombstone so an in-flight sync pass can't resurrect wiped chats
        for id in localIds {
            DeletedChatsTracker.shared.markAsDeleted(id)
        }

        await clearAllChatsFromDevice()
        // The device wipe clears the in-memory key reference; restore it so
        // newly created chats keep syncing.
        reloadEncryptionKey()
        createNewChat()
    }

    /// Removes all cloud (non-local) chats from the device
    @MainActor
    func deleteNonLocalChats() async {
        // Delete all cloud chats from storage (the cloud store only has cloud chats)
        if let userId = currentUserId {
            try? await EncryptedFileStorage.cloud.deleteAllChats(userId: userId)
        }
        chats = []
        hasMoreChats = false
        paginationToken = nil
        // If the current chat was a cloud chat, switch to a local one
        if let current = currentChat, !current.isLocalOnly {
            if let first = localChats.first {
                currentChat = first
            } else {
                createNewChat()
            }
        }
    }

    /// Initialize cloud sync when user signs in
    private func initializeCloudSync() async {
        do {
            // Mark that initial sync has been done to avoid duplicate
            hasPerformedInitialSync = true
            
            // Initialize cloud sync service
            try await cloudSync.initialize()
            
            // Perform sync
            let _ = await cloudSync.syncAllChats()
            
            // Load and display synced chats from file index (cloud chats only, paginated)
            let result = await loadFirstPageOfChats(
                userId: currentUserId,
                filter: \.isCloudDisplayable
            )

            await MainActor.run {
                self.chats = result.chats
                normalizeChatsArray()

                // Only select the first chat if we don't have a current chat selected
                if self.currentChat == nil, let first = self.chats.first {
                    self.currentChat = first
                }

                // Mark that we've loaded the initial page
                self.hasLoadedInitialPage = true
                self.isPaginationActive = result.totalEntries > 0

                // Set hasMoreChats based on total count
                self.hasMoreChats = result.totalEntries > Constants.Pagination.chatsPerPage
            }
            
            // Setup pagination token
            await setupPaginationForAppRestart()
        } catch {
            await MainActor.run {
                self.syncErrors.append(error.localizedDescription)
            }
        }
    }

    /// Continues the sign-in flow (encryption, cloud sync, profile sync) after migration decision
    private func startEncryptedSyncFlow() async {
        // Avoid double starts
        if isSignInInProgress { return }
        isSignInInProgress = true
        
        // Ensure auto-sync timer is scheduled (will no-op if gated)
        setupAutoSyncTimer()
        
        do {
            // Ensure an encryption key exists before proceeding
            guard EncryptionService.shared.hasEncryptionKey() else {
                await MainActor.run {
                    self.isFirstTimeUser = true
                    self.isSignInInProgress = false
                }
                return
            }

            // Initialize encryption with the existing key
            let key = try await EncryptionService.shared.initialize()
            await MainActor.run { self.encryptionKey = key }
            
            // Initialize cloud sync service and perform initial sync
            await initializeCloudSync()

            // Sync user profile settings
            await ProfileManager.shared.performFullSync()
            
            await MainActor.run {
                self.lastSyncDate = Date()
                // After sync completes, ensure we have proper chat setup
                if self.chats.isEmpty {
                    self.createNewChat()
                } else {
                    self.ensureBlankChatAtTop()
                }
                self.isSignInInProgress = false
            }
        } catch {
            await MainActor.run {
                self.isFirstTimeUser = true
                self.showEncryptionSetup = true
                self.isSignInInProgress = false
            }
        }
    }
    
    // MARK: - Pagination Methods
    
    /// Setup pagination state for app restart (when already authenticated)
    private func setupPaginationForAppRestart() async {
        // Try to get pagination token from cloud to enable Load More
        do {
            // Get the list result to check if there are more pages
            if let listResult = try? await CloudStorageService.shared.listChats(
                limit: Constants.Pagination.chatsPerPage,
                continuationToken: nil,
                includeContent: false
            ) {
                await MainActor.run {
                    self.paginationToken = listResult.nextContinuationToken
                    self.hasMoreChats = listResult.hasMore
                    self.isPaginationActive = true
                    self.hasLoadedInitialPage = true
                }
            }
        }
    }
    
    /// Perform initial sync if it hasn't been done yet
    private func performInitialSyncIfNeeded() async {
        guard !hasPerformedInitialSync else { return }
        guard hasChatAccess else { return }
        
        hasPerformedInitialSync = true
        
        do {
            // Initialize encryption
            let key = try await EncryptionService.shared.initialize()
            await MainActor.run {
                self.encryptionKey = key
            }
            
            // Initialize cloud sync
            try await cloudSync.initialize()
            
            // Perform immediate sync
            let _ = await cloudSync.syncAllChats()
            
            // Update last sync date
            await MainActor.run {
                self.lastSyncDate = Date()
            }
            
            // Setup pagination after sync
            await setupPaginationForAppRestart()
            
            // Load and display cloud chats after sync from file index
            let result = await loadFirstPageOfChats(
                userId: currentUserId,
                filter: \.isCloudDisplayable
            )
            await MainActor.run {
                self.chats = result.chats
                normalizeChatsArray()
            }
        } catch {
            #if DEBUG
            print("Failed to perform initial sync: \(error)")
            #endif
        }
    }
    
    /// Loads the first page of chats from file storage, sorted newest-first.
    /// Returns the loaded chats and the total number of matching index entries
    /// (useful for determining whether more pages exist).
    /// Loads ALL chats from the local-only store (no pagination). Used when cloud sync is disabled.
    private func loadAllLocalChats(userId: String?) async -> [Chat] {
        guard let userId = userId else { return [] }
        return ((try? await EncryptedFileStorage.local.loadAllChats(userId: userId)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadFirstPageOfChats(
        userId: String?,
        excluding excludedIds: Set<String> = [],
        filter: ((ChatIndexEntry) -> Bool)? = nil
    ) async -> (chats: [Chat], totalEntries: Int) {
        guard let userId = userId else { return ([], 0) }
        let index = await Chat.loadChatIndex(userId: userId)
        let filtered = index
            .filter { !excludedIds.contains($0.id) }
            .filter { filter?($0) ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
        let firstPageIds = filtered.prefix(Constants.Pagination.chatsPerPage).map(\.id)

        let chats = await Chat.loadChats(chatIds: firstPageIds, userId: userId)
            .sorted { $0.updatedAt > $1.updatedAt }

        return (chats, filtered.count)
    }

    /// Clean up chats beyond first page (called on app launch to ensure clean state)
    /// With per-chat file storage, each chat is its own file so no blob trimming is needed.
    private func cleanupPaginatedChats() async {
        // No-op: per-chat file storage doesn't need blob trimming
    }
    
    /// Load more chats (called when user scrolls to bottom)
    func loadMoreChats() async {
        // Prevent duplicate loads
        guard !isLoadingMore else {
            return
        }
        
        // Must have a token to load more
        guard let token = paginationToken else {
            // No token but hasMoreChats might still be true after sync
            // In this case, we should NOT set hasMoreChats to false automatically
            // Only set it to false if we're certain there are no more
            if !hasMoreChats {
                // Already false, nothing to do
                return
            }
            
            // If hasMoreChats is true but no token, this is likely after a sync
            // Don't change hasMoreChats - the sync logic should have set it correctly
            return
        }
        
        await MainActor.run {
            self.isLoadingMore = true
            self.hasAttemptedLoadMore = true  // Track that user has loaded additional pages
        }
        
        // Load next page with the token
        let result = await cloudSync.loadChatsWithPagination(
            limit: Constants.Pagination.chatsPerPage,
            continuationToken: token,
            loadLocal: false  // Don't fall back to local when paginating
        )
        
        await MainActor.run {
            // Convert and append new chats - filter out any that fail to convert
            let newChats = result.chats.compactMap { storedChat -> Chat? in
                if let chat = storedChat.toChat() {
                    return chat
                } else {
                    #if DEBUG
                    print("Warning: Could not convert StoredChat to Chat during pagination - skipping chat \(storedChat.id)")
                    #endif
                    return nil
                }
            }

            // Filter out any duplicates
            let existingIds = Set(self.chats.map { $0.id })
            let uniqueNewChats = newChats.filter { !existingIds.contains($0.id) }

            // DON'T save paginated chats to storage - keep them in memory only
            // Only append to the visible chats array
            if !uniqueNewChats.isEmpty {
                self.chats.append(contentsOf: uniqueNewChats)
                self.chats.sort { chat1, chat2 in
                    if chat1.isBlankChat { return true }
                    if chat2.isBlankChat { return false }
                    return chat1.updatedAt > chat2.updatedAt
                }
            }
            
            // Update pagination state
            self.hasMoreChats = result.hasMore
            self.paginationToken = result.nextToken
            self.isLoadingMore = false
        }
    }
    
    /// Intelligently update chats after sync without resetting pagination
    @MainActor
    private func updateChatsAfterSync() async {
        guard let userId = currentUserId else { return }

        // IMPORTANT: Preserve pagination token before updating
        let savedPaginationToken = self.paginationToken
        let savedIsPaginationActive = self.isPaginationActive

        // IMPORTANT: Preserve the current chat ID so it stays in the array even if beyond first page
        let currentChatId = self.currentChat?.id

        // IMPORTANT: Preserve locally modified chats and chats with active streams
        let locallyModifiedChats = chats.filter { $0.locallyModified || $0.hasActiveStream || streamingTracker.isStreaming($0.id) }
        let locallyModifiedIds = Set(locallyModifiedChats.map { $0.id })

        // Load first page of cloud chats from files, excluding locally modified ones
        let result = await loadFirstPageOfChats(userId: userId, excluding: locallyModifiedIds, filter: \.isCloudDisplayable)

        // Combine: locally modified chats + synced chats from files
        let sortedChats = (locallyModifiedChats + result.chats).sorted { $0.updatedAt > $1.updatedAt }

        // Keep track of currently loaded chat IDs to preserve pagination
        let currentlyLoadedIds = Set(chats.map { $0.id })
        
        // Separate chats into categories
        let twoMinutesAgo = Date().addingTimeInterval(-Constants.Pagination.recentChatThresholdSeconds)
        let unsavedChats = sortedChats.filter { $0.isBlankChat }
        let recentChats = sortedChats.filter {
            $0.createdAt >= twoMinutesAgo &&
            !$0.isBlankChat
        }
        let syncedChats = sortedChats.filter {
            !$0.isBlankChat &&
            $0.createdAt < twoMinutesAgo
        }
        
        // Build the updated chat list
        var updatedChats: [Chat] = []
        
        // 1. Add all unsaved chats (blank/temporary)
        updatedChats.append(contentsOf: unsavedChats)
        
        // 2. Add recent chats (last 2 minutes)
        updatedChats.append(contentsOf: recentChats)
        
        // 3. For synced chats, preserve pagination state
        if hasAttemptedLoadMore && currentlyLoadedIds.count > Constants.Pagination.chatsPerPage {
            // User has loaded more pages - preserve all currently loaded synced chats
            let syncedChatsToShow = syncedChats.filter { chat in
                // Keep if it was already loaded OR if it's in the first page positions OR if it's the current chat
                currentlyLoadedIds.contains(chat.id) ||
                syncedChats.firstIndex(where: { $0.id == chat.id }) ?? Int.max < Constants.Pagination.chatsPerPage ||
                (currentChatId != nil && chat.id == currentChatId)
            }
            updatedChats.append(contentsOf: syncedChatsToShow)
        } else {
            // Only first page loaded - include first page AND current chat if it exists
            var syncedChatsToShow = Array(syncedChats.prefix(Constants.Pagination.chatsPerPage))
            if let currentChatId = currentChatId,
               let currentChat = syncedChats.first(where: { $0.id == currentChatId }),
               !syncedChatsToShow.contains(where: { $0.id == currentChatId }) {
                syncedChatsToShow.append(currentChat)
            }
            updatedChats.append(contentsOf: syncedChatsToShow)
        }
        
        // Sort non-blank chats by latest activity before normalization
        updatedChats.sort { chat1, chat2 in
            if chat1.isBlankChat { return true }
            if chat2.isBlankChat { return false }
            return chat1.updatedAt > chat2.updatedAt
        }

        // Set chats and normalize to ensure exactly one blank chat at position 0
        self.chats = updatedChats
        normalizeChatsArray()

        // IMPORTANT: Always update currentChat to point to the instance in the chats array
        // This ensures currentChat is never stale and always references a chat that's in the array
        if let currentChatId = currentChatId,
           let updatedChat = self.chats.first(where: { $0.id == currentChatId }) {
            self.currentChat = updatedChat
        }
        
        // Update hasMoreChats conservatively to preserve server-provided pagination
        let displayedSyncedChats = chats.filter { !$0.isBlankChat }.count
        // Use total entries from result + locally modified count as a proxy for total index size
        let totalIndexEntries = result.totalEntries + locallyModifiedChats.count

        // Set to true if we clearly have more in the index than are displayed
        if totalIndexEntries > displayedSyncedChats {
            self.hasMoreChats = true
        } else if self.paginationToken == nil && totalIndexEntries <= Constants.Pagination.chatsPerPage {
            // Only set to false when not using remote pagination and we are certain the total fits on one page
            self.hasMoreChats = false
        }
        // Otherwise, preserve existing hasMoreChats which may have been set from remote list
        
        // IMPORTANT: Restore pagination state that was saved at the beginning
        // This ensures the pagination token doesn't get lost during sync
        if savedIsPaginationActive {
            self.paginationToken = savedPaginationToken
            self.isPaginationActive = savedIsPaginationActive
        }
    }
    
    /// Reset pagination and reload all chats from storage (used after sync)
    @MainActor
    private func resetPaginationAndReloadChats() async {
        let result = await loadFirstPageOfChats(
            userId: currentUserId,
            filter: \.isCloudDisplayable
        )
        self.chats = result.chats
        normalizeChatsArray()
        self.hasMoreChats = result.totalEntries > Constants.Pagination.chatsPerPage
    }
    
    /// Perform a full sync with the cloud
    func performFullSync() async {
        // Gate sync when cloud sync is disabled
        if !SettingsManager.shared.isCloudSyncEnabled {
            return
        }

        // Gate sync until encryption key is set up
        if !EncryptionService.shared.hasEncryptionKey() {
            return
        }

        await MainActor.run {
            self.isSyncing = true
            self.syncErrors = []
        }
        
        let result = await cloudSync.syncAllChats()
        
        // Update chats if there were changes (await this before marking sync complete)
        if result.downloaded > 0 || result.uploaded > 0 || result.deleted > 0 {
            await self.updateChatsAfterSync()
        }
        
        // Always refresh pagination token and hasMore state from the server after a sync
        // This guards against cold-start races where the token wasn't available yet
        await self.setupPaginationForAppRestart()
        
        // Also sync profile settings
        await ProfileManager.shared.performFullSync()
        
        // Re-load localChats from the local-only store
        let freshLocal = await loadAllLocalChats(userId: self.currentUserId)

        await MainActor.run {
            self.localChats = freshLocal
            self.isSyncing = false
            self.lastSyncDate = Date()
            self.ensureBlankChatAtTop()
            
            if !result.errors.isEmpty {
                self.syncErrors = result.errors
            }
        }
    }
    
    /// Get the current encryption key (for display purposes only)
    func getCurrentEncryptionKey() -> String? {
        return encryptionKey
    }

    /// Reload the cached encryption key reference from the keychain.
    func reloadEncryptionKey() {
        encryptionKey = EncryptionService.shared.getKey()
    }
    
    /// Set encryption key (for key rotation)
    func setEncryptionKey(
        _ key: String,
        mode: CloudKeyActivationMode = .recoverExisting
    ) async throws {
        do {
            switch mode {
            case .recoverExisting:
                _ = try await CloudKeyAuthorizationStore.shared.applyPrimaryKeyWithValidation(key)
            case .explicitStartFresh:
                // Stage the key in memory so the enclave handshake runs
                // against it without writing it to the Keychain first. Only
                // after the enclave registers the start-fresh key (or
                // confirms the remote is empty / already bound to this key)
                // do we persist it. If the enclave can't be reached we throw
                // and discard the staged key, so a new key is never stranded
                // locally while the enclave keeps the old one.
                try await EncryptionService.shared.setKey(key, persist: false)
                do {
                    try await CloudKeyAuthorizationStore.shared.registerStartFreshKeyIfNeeded()
                    try EncryptionService.shared.persistCurrentKeyState()
                } catch {
                    EncryptionService.shared.discardStagedKeyState()
                    throw error
                }
                // The enclave has already rebound the account to this key
                // and the Keychain has persisted it; the local mode stamp
                // is best-effort. Failing it must not wipe the only copy
                // of the now-authoritative key, so writes just stay gated
                // until a later preflight validation re-stamps the hint.
                _ = CloudKeyAuthorizationStore.shared.authorizeCurrentPrimaryKey(mode: .explicitStartFresh)
            }

            await MainActor.run {
                self.encryptionKey = EncryptionService.shared.getKey()
                self.showEncryptionSetup = false
            }

            // A v1 user activating their key on a fresh device has legacy
            // cloud data but no registered key: the launch-time migration
            // pass ran before any key existed, so without a re-kick the
            // key is never adopted and cloud writes stay deferred for the
            // whole session. Run the migration again now that a key is
            // active so adoption happens in-session.
            Task.detached(priority: .background) {
                _ = await LegacyBlobMigration.runAndFinalize()
                await PasskeyManager.shared.refreshBundleState()
            }

            await ProfileManager.shared.retryDecryptionWithNewKey()
            await retryDecryptionAndReloadChats()

            // If this was first-time setup, initialize cloud sync and load chats
            if isFirstTimeUser {
                await MainActor.run {
                    self.isFirstTimeUser = false
                }
                try await cloudSync.initialize()
                await performFullSync()
                
                // After first-time sync, check if we have chats
                await MainActor.run {
                    if self.chats.isEmpty {
                        self.createNewChat()
                    } else {
                        // Select the most recent chat
                        if let mostRecent = self.chats.first {
                            self.currentChat = mostRecent
                        }
                    }
                }
            }

            // If passkey is active, re-encrypt the backup with the updated key bundle
            if passkeyManager.passkeyActive {
                await passkeyManager.updatePasskeyBackup()
            }
        } catch {
            await MainActor.run {
                self.syncErrors.append(error.localizedDescription)
            }
            throw error  // Re-throw to let caller handle it
        }
    }
    
    /// Retry decryption of failed chats with the current key
    func retryDecryptionWithNewKey() async {
        await MainActor.run {
            self.isSyncing = true
        }
        
        let decryptedCount = await cloudSync.retryDecryptionWithNewKey()
        
        await MainActor.run {
            self.isSyncing = false
            if decryptedCount > 0 {
                self.lastSyncDate = Date()
            }
        }
        
        // Reload cloud chats after decryption
        let result = await loadFirstPageOfChats(userId: currentUserId, filter: \.isCloudDisplayable)
        await MainActor.run {
            self.chats = result.chats
            normalizeChatsArray()
        }
    }
    
    /// Re-encrypt and upload all chats with current key
    func reencryptAndUploadChats() async {
        await MainActor.run {
            self.isSyncing = true
        }
        
        let result = await cloudSync.reencryptAndUploadChats()
        
        await MainActor.run {
            self.isSyncing = false
            if result.uploaded > 0 {
                self.lastSyncDate = Date()
            }
            if result.errors.count > 0 {
                self.syncErrors.append(contentsOf: result.errors)
            }
        }
    }
}

// MARK: - LLM Title Generation
extension ChatViewModel {
    /// Generates a concise chat title using the title model, based on the assistant's first response.
    fileprivate func generateLLMTitle(from messages: [Message]) async -> String? {
        // Find the first assistant message
        guard let assistantMessage = messages.first(where: { $0.role == .assistant }),
              !assistantMessage.content.isEmpty else {
            return nil
        }

        // Truncate content to word threshold
        let words = assistantMessage.content.split(separator: " ", omittingEmptySubsequences: true)
        let truncatedContent = words
            .prefix(Constants.TitleGeneration.wordThreshold)
            .joined(separator: " ")

        do {
            let title = try await SummarizerService.shared.summarize(
                content: truncatedContent,
                style: .titleSummary
            )

            guard !title.isEmpty else { return nil }
            return title
        } catch {
            return nil
        }
    }

    // MARK: - Audio Recording

    /// Check if audio input is available (premium feature with audio model)
    var canUseAudioInput: Bool {
        hasPremiumAccess && AppConfig.shared.audioModel != nil
    }

    /// Start recording audio
    func startAudioRecording() async {
        guard canUseAudioInput else { return }

        audioError = nil

        // Check if permission was previously denied
        if !AudioRecordingService.shared.hasPermission {
            let granted = await AudioRecordingService.shared.requestPermission()
            if !granted {
                showMicrophonePermissionAlert = true
                return
            }
        }

        do {
            try AudioRecordingService.shared.startRecording()
            isRecording = true
        } catch {
            audioError = error.localizedDescription
        }
    }

    /// Stop recording and transcribe the audio
    func stopAudioRecordingAndTranscribe() async -> String? {
        guard isRecording else { return nil }

        isRecording = false

        guard let fileURL = AudioRecordingService.shared.stopRecording(),
              let audioModel = AppConfig.shared.audioModel,
              let client = client else {
            return nil
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcription = try await AudioRecordingService.shared.transcribe(
                fileURL: fileURL,
                client: client,
                model: audioModel.modelName
            )
            return transcription
        } catch {
            // Retry once with a fresh token if the error is an auth failure
            if ChatViewModel.isAuthenticationError(error) {
                await refreshSessionTokenForRetry()
                if let retryClient = self.client {
                    do {
                        let transcription = try await AudioRecordingService.shared.transcribe(
                            fileURL: fileURL,
                            client: retryClient,
                            model: audioModel.modelName
                        )
                        return transcription
                    } catch {
                        audioError = error.localizedDescription
                        return nil
                    }
                }
            }
            audioError = error.localizedDescription
            return nil
        }
    }

    /// Cancel recording without transcribing
    func cancelAudioRecording() {
        isRecording = false
        AudioRecordingService.shared.cancelRecording()
    }

}
