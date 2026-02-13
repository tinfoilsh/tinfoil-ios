//
//  ChatViewModel.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import Foundation
import Combine
import SwiftUI
import TinfoilAI
import OpenAI
import AVFoundation

enum ChatStorageTab: String {
    case cloud
    case local
}

@MainActor
class ChatViewModel: ObservableObject {
    // Published properties for UI updates
    @Published var chats: [Chat] = []
    @Published var localChats: [Chat] = []
    @Published var currentChat: Chat?
    @Published var activeStorageTab: ChatStorageTab = .cloud
    @Published var isLoading: Bool = false
    @Published var thinkingSummary: String = ""
    @Published var webSearchSummary: String = ""
    @Published var showVerifierSheet: Bool = false
    @Published var scrollTargetMessageId: String? = nil 
    @Published var scrollTargetOffset: CGFloat = 0 
    /// When set to true, the input field should become first responder (focus keyboard)
    @Published var shouldFocusInput: Bool = false
    @Published var isScrollInteractionActive: Bool = false
    @Published var isAtBottom: Bool = true
    @Published var scrollToBottomTrigger: UUID = UUID()
    @Published var isClientInitializing: Bool = false
    @Published var isWebSearchEnabled: Bool = false

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
                UserDefaults.standard.set(date, forKey: "lastSyncDate_\(userId)")
            } else if let userId = currentUserId {
                UserDefaults.standard.removeObject(forKey: "lastSyncDate_\(userId)")
            }
        }
    }
    @Published var syncErrors: [String] = []
    private var encryptionKey: String?  // Keep private for security
    @Published var isFirstTimeUser: Bool = false
    @Published var showEncryptionSetup: Bool = false
    @Published var shouldShowKeyImport: Bool = false
    private let cloudSync = CloudSyncService.shared
    private let streamingTracker = StreamingTracker.shared
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
    
    // Model properties
    @Published var currentModel: ModelType

    // View state for verifier
    @Published var verifierView: VerifierView?

    // Audio recording properties
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var audioError: String? = nil
    @Published var showMicrophonePermissionAlert: Bool = false

    // Attachment properties
    @Published var pendingAttachments: [Attachment] = []
    @Published var isProcessingAttachment: Bool = false
    @Published var attachmentError: String? = nil
    @Published var pendingImageThumbnails: [String: String] = [:]
    // Private properties
    private var client: TinfoilAI?
    private var currentTask: Task<Void, Error>?
    private var autoSyncTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
    private var networkStatusCancellable: AnyCancellable?
    private var streamUpdateTimer: Timer?
    private var pendingStreamUpdate: Chat?
    private var pendingSaveTask: Task<Void, Never>?
    private var lastKnownAuthState: Bool?
    
    // Auth reference for Premium features
    @Published var authManager: AuthManager? {
        didSet {
            // Load user-specific last sync date when auth changes
            if let userId = currentUserId {
                lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate_\(userId)") as? Date
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
            }
        }
    }
    
    var messages: [Message] {
        currentChat?.messages ?? []
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
        return "pagination_\(suffix)_\(userId)"
    }
    
    private func persistPaginationStateIfPossible() {
        guard shouldPersistPaginationState else { return }
        guard let userId = currentUserId else { return }
        if let token = paginationToken, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: "pagination_token_\(userId)")
        } else {
            UserDefaults.standard.removeObject(forKey: "pagination_token_\(userId)")
        }
        UserDefaults.standard.set(hasMoreChats, forKey: "pagination_hasMore_\(userId)")
        UserDefaults.standard.set(isPaginationActive, forKey: "pagination_active_\(userId)")
        UserDefaults.standard.set(hasLoadedInitialPage, forKey: "pagination_loadedFirst_\(userId)")
        UserDefaults.standard.set(hasAttemptedLoadMore, forKey: "pagination_attempted_\(userId)")
    }
    
    private func loadPersistedPaginationState() {
        guard let userId = currentUserId else { return }
        if let token = UserDefaults.standard.string(forKey: "pagination_token_\(userId)") {
            paginationToken = token
        }
        if UserDefaults.standard.object(forKey: "pagination_hasMore_\(userId)") != nil {
            hasMoreChats = UserDefaults.standard.bool(forKey: "pagination_hasMore_\(userId)")
        }
        if UserDefaults.standard.object(forKey: "pagination_active_\(userId)") != nil {
            isPaginationActive = UserDefaults.standard.bool(forKey: "pagination_active_\(userId)")
        }
        if UserDefaults.standard.object(forKey: "pagination_loadedFirst_\(userId)") != nil {
            hasLoadedInitialPage = UserDefaults.standard.bool(forKey: "pagination_loadedFirst_\(userId)")
        }
        if UserDefaults.standard.object(forKey: "pagination_attempted_\(userId)") != nil {
            hasAttemptedLoadMore = UserDefaults.standard.bool(forKey: "pagination_attempted_\(userId)")
        }
        // Enable persistence after we've loaded any saved state to prevent clobbering
        shouldPersistPaginationState = true
    }
    
    // Get current user ID from auth manager
    private var currentUserId: String? {
        guard let authManager = authManager,
              authManager.isAuthenticated,
              let userData = authManager.localUserData,
              let userId = userData["id"] as? String else {
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
        self.isWebSearchEnabled = SettingsManager.shared.webSearchEnabled

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
        
        // Load any previously persisted pagination state (per-user)
        // Delay enabling persistence until after load to avoid overwriting saved values
        loadPersistedPaginationState()

        // Setup app lifecycle observers
        setupAppLifecycleObservers()

        // Setup network status observer for automatic retry on reconnection
        setupNetworkStatusObserver()

        // Initial sync will be triggered when authManager is set (see authManager didSet)

        // Setup Tinfoil client immediately
        setupTinfoilClient()
    }
    
    deinit {
        // Stop auto-sync timer
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil

        // Stop stream update timer
        streamUpdateTimer?.invalidate()
        streamUpdateTimer = nil

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
                if self.isLoading {
                    return
                }
                
                // Skip if current chat has active stream
                if let currentChat = self.currentChat, 
                   (currentChat.hasActiveStream || self.streamingTracker.isStreaming(currentChat.id)) {
                    return
                }
                
                
                // Perform sync in background
                do {
                    // Use smart sync for periodic sync (checks if sync is needed first)
                    let syncResult = await self.cloudSync.smartSync()
                    
                    // Update last sync date after successful sync
                    self.lastSyncDate = Date()
                    
                    // If we downloaded new chats, reload the chat list
                    if syncResult.downloaded > 0 {
                        // Use intelligent update that preserves pagination
                        await self.updateChatsAfterSync()
                        
                        // Force UI update
                        self.objectWillChange.send()
                        
                        // Restore current chat selection if it still exists
                        if let currentChatId = self.currentChat?.id,
                           let location = self.findChatLocation(currentChatId) {
                            self.currentChat = location.isLocal ? self.localChats[location.index] : self.chats[location.index]
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
                } catch {
                }
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
                        if syncResult.downloaded > 0 {
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
                let apiKey = await AppConfig.shared.getApiKey()

                client = try await TinfoilAI.create(
                    apiKey: apiKey,
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

        guard !isLoading else {
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
        activeStorageTab = tab

        let shouldBeLocal = tab == .local

        // If on a blank chat, switch to the blank chat for the target tab
        if currentChat?.isBlankChat == true {
            createNewChat(isLocalOnly: shouldBeLocal)
            return
        }

        let targetList = shouldBeLocal ? localChats : chats
        if let first = targetList.first {
            selectChat(first)
        } else {
            createNewChat(isLocalOnly: shouldBeLocal)
        }
    }

    /// Creates a new chat and sets it as the current chat
    func createNewChat(language: String? = nil, modelType: ModelType? = nil, isLocalOnly: Bool? = nil) {
        // Allow creating new chats for all authenticated users
        guard hasChatAccess else { return }
        
        // Cancel any ongoing generation first
        if isLoading {
            cancelGeneration()
        }

        let shouldBeLocal: Bool
        if let explicit = isLocalOnly {
            shouldBeLocal = explicit
        } else if !SettingsManager.shared.isCloudSyncEnabled {
            shouldBeLocal = true
        } else {
            shouldBeLocal = activeStorageTab == .local
        }

        // Check if we already have a blank chat in the target list
        if shouldBeLocal {
            if let existing = localChats.first(where: { $0.isBlankChat }) {
                selectChat(existing)
                shouldFocusInput = true
                return
            }
        } else {
            if let existing = chats.first(where: { $0.isBlankChat }) {
                selectChat(existing)
                shouldFocusInput = true
                return
            }
        }
        
        // Create new chat with temporary ID (instant, no network call)
        let newChat = Chat.create(
            modelType: modelType ?? currentModel,
            language: language,
            userId: currentUserId,
            isLocalOnly: shouldBeLocal
        )

        if shouldBeLocal {
            localChats.insert(newChat, at: 0)
        } else {
            chats.insert(newChat, at: 0)
        }
        selectChat(newChat)
        shouldFocusInput = true
    }
    
    /// Selects a chat as the current chat
    func selectChat(_ chat: Chat) {
        // Cancel any ongoing generation first
        if isLoading {
            cancelGeneration()
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
    }
    
    /// Deletes a chat by ID
    func deleteChat(_ id: String) {
        // Allow deleting chats for all authenticated users
        guard hasChatAccess else { return }

        let isLocal: Bool

        if let index = localChats.firstIndex(where: { $0.id == id }) {
            localChats.remove(at: index)
            isLocal = true
        } else if let index = chats.firstIndex(where: { $0.id == id }) {
            chats.remove(at: index)
            isLocal = false
        } else {
            return
        }

        // Mark as deleted for cloud sync (local-only chats are never uploaded)
        if !isLocal {
            DeletedChatsTracker.shared.markAsDeleted(id)
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

        // Delete from file storage and cloud
        let userId = currentUserId
        Task {
            await Chat.deleteChatFromStorage(chatId: id, userId: userId)
            if !isLocal && SettingsManager.shared.isCloudSyncEnabled {
                do {
                    try await cloudSync.deleteFromCloud(id)
                } catch {
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

    /// Sends a user message and generates a response
    func sendMessage(text: String) {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        guard hasText || hasAttachments else { return }

        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        // Update UI state
        isLoading = true

        // Merge attachment data into message fields
        var combinedDocumentContent: String? = nil
        var messageImageData: [ImageData] = []
        var messageAttachments: [Attachment] = []

        for attachment in pendingAttachments {
            messageAttachments.append(attachment)
            if let docContent = attachment.documentContent, !docContent.isEmpty {
                if let existing = combinedDocumentContent {
                    combinedDocumentContent = existing + "\n\n---\n\n" + docContent
                } else {
                    combinedDocumentContent = docContent
                }
            }
            if let imgBase64 = attachment.imageBase64, !imgBase64.isEmpty {
                messageImageData.append(ImageData(base64: imgBase64, mimeType: Constants.Attachments.defaultImageMimeType))
            }
        }

        clearPendingAttachments()

        // Create and add user message
        let userMessage = Message(
            role: .user,
            content: text,
            attachments: messageAttachments,
            documentContent: combinedDocumentContent,
            imageData: messageImageData.isEmpty ? nil : messageImageData
        )
        addMessage(userMessage)

        // If this is the first message, mark as modified (title will be generated after assistant reply)
        if var chat = currentChat, chat.messages.count == 1 {
            chat.updatedAt = Date()
            chat.locallyModified = true
            updateChat(chat)
        }

        generateResponse()
    }

    // MARK: - Attachment Management

    func addDocumentAttachment(url: URL, fileName: String) {
        isProcessingAttachment = true
        attachmentError = nil

        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(
            id: attachmentId,
            type: .document,
            fileName: fileName,
            processingState: .processing
        )
        pendingAttachments.append(attachment)

        Task {
            do {
                let text = try await DocumentProcessingService.shared.extractText(from: url)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

                attachment.documentContent = text
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
            isProcessingAttachment = false
        }
    }

    func addImageAttachment(data: Data, fileName: String) {
        isProcessingAttachment = true
        attachmentError = nil

        let attachmentId = UUID().uuidString.lowercased()
        var attachment = Attachment(
            id: attachmentId,
            type: .image,
            fileName: fileName,
            fileSize: Int64(data.count),
            processingState: .processing
        )
        pendingAttachments.append(attachment)

        Task {
            do {
                let processed = try await ImageProcessingService.shared.processImage(data: data)

                attachment.imageBase64 = processed.base64
                attachment.thumbnailBase64 = processed.thumbnailBase64
                attachment.fileSize = processed.fileSize
                attachment.processingState = .completed

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
            isProcessingAttachment = false
        }
    }

    func removePendingAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
        pendingImageThumbnails.removeValue(forKey: id)
        if pendingAttachments.isEmpty {
            attachmentError = nil
        }
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
        pendingImageThumbnails.removeAll()
        attachmentError = nil
        isProcessingAttachment = false
    }

    /// Generates an assistant response for the current conversation (expects user message to already be in chat)
    private func generateResponse() {
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        // Update UI state
        isLoading = true

        // Create initial empty assistant message as a placeholder
        let assistantMessage = Message(role: .assistant, content: "", isCollapsed: true)
        addMessage(assistantMessage)

        // Set the chat as having an active stream
        if var chat = currentChat {
            chat.hasActiveStream = true
            updateChat(chat)
            // Track streaming for cloud sync
            streamingTracker.startStreaming(chat.id)
        }
        
        // Store the current chat for stream validation
        // We'll track by messages rather than ID to handle ID changes
        let _ = currentChat
        let _ = currentChat?.messages.count ?? 0
        let streamChatId = currentChat?.id
        
        // Cancel any existing task
        currentTask?.cancel()
        
        // Create and start a new task for the streaming request
        currentTask = Task {
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

                // Create the stream with proper parameters
                let modelId = currentModel.modelName
                
                // Add system message first with language preference
                let settingsManager = SettingsManager.shared
                let profileManager = ProfileManager.shared
                var systemPrompt: String
                
                // Use custom prompt if enabled (from ProfileManager), otherwise use default
                if let customPrompt = profileManager.getCustomSystemPrompt() {
                    systemPrompt = customPrompt
                } else if settingsManager.isUsingCustomPrompt && !settingsManager.customSystemPrompt.isEmpty {
                    systemPrompt = settingsManager.customSystemPrompt
                } else {
                    systemPrompt = AppConfig.shared.systemPrompt
                }
                
                // Replace MODEL_NAME placeholder with current model name
                systemPrompt = systemPrompt.replacingOccurrences(of: "{MODEL_NAME}", with: currentModel.fullName)
                
                // Replace language placeholder - use ProfileManager language first, then settings preference
                let languageToUse: String
                if !profileManager.language.isEmpty && profileManager.language != "English" {
                    // Use the language from ProfileManager
                    languageToUse = profileManager.language
                } else if settingsManager.selectedLanguage != "System" {
                    // Use the language from settings
                    languageToUse = settingsManager.selectedLanguage
                } else if let chat = currentChat, let chatLanguage = chat.language {
                    // Fall back to chat's language if set
                    languageToUse = chatLanguage
                } else {
                    // Default to English
                    languageToUse = "English"
                }
                systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: languageToUse)
                
                // Add personalization - use ProfileManager first, then fall back to SettingsManager
                var personalizationXML = ""
                if let profilePersonalization = profileManager.getPersonalizationPrompt() {
                    personalizationXML = "<user_preferences>\n\(profilePersonalization)\n</user_preferences>"
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
                
                // Process rules with same replacements
                var processedRules = AppConfig.shared.rules
                if !processedRules.isEmpty {
                    processedRules = processedRules.replacingOccurrences(of: "{MODEL_NAME}", with: currentModel.fullName)
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
                let maxMessages = profileManager.maxPromptMessages > 0 ? profileManager.maxPromptMessages : settingsManager.maxMessages
                let chatQuery = ChatQueryBuilder.buildQuery(
                    modelId: modelId,
                    systemPrompt: systemPrompt,
                    rules: processedRules,
                    conversationMessages: self.messages,
                    maxMessages: maxMessages,
                    webSearchEnabled: self.isWebSearchEnabled,
                    isMultimodal: self.currentModel.isMultimodal
                )

                // Web search state tracking
                var collectedSources: [WebSearchSource] = []
                let isWebSearchEnabled = self.isWebSearchEnabled

                // Create stream with web search callback if enabled
                let stream: AsyncThrowingStream<ChatStreamResult, Error>
                if isWebSearchEnabled {
                    stream = client.chatsStream(query: chatQuery) { [weak self] event in
                        Task { @MainActor in
                            guard let self = self else { return }
                            guard var chat = self.currentChat,
                                  !chat.messages.isEmpty,
                                  let lastIndex = chat.messages.indices.last else { return }

                            // Read current state from the message to preserve sources added by the streaming loop
                            let existingSources = chat.messages[lastIndex].webSearchState?.sources ?? []

                            // Update web search state based on event
                            switch event.status {
                            case .inProgress, .searching:
                                chat.messages[lastIndex].webSearchState = WebSearchState(
                                    query: event.action?.query,
                                    status: .searching,
                                    sources: existingSources
                                )
                                self.webSearchSummary = event.action?.query.map { "Searching: \($0)" } ?? "Searching the web..."
                            case .completed:
                                chat.messages[lastIndex].webSearchState?.status = .completed
                                self.webSearchSummary = ""
                            case .failed:
                                chat.messages[lastIndex].webSearchState?.status = .failed
                                self.webSearchSummary = ""
                            case .blocked:
                                chat.messages[lastIndex].webSearchState = WebSearchState(
                                    query: event.action?.query,
                                    status: .blocked,
                                    reason: event.reason
                                )
                                self.webSearchSummary = ""
                            }

                            self.updateChat(chat, throttleForStreaming: true)
                        }
                    }
                } else {
                    stream = client.chatsStream(query: chatQuery)
                }

                var thinkStartTime: Date? = nil
                var hasThinkTag = false
                var thoughtsBuffer = ""
                var isInThinkingMode = false
                var isUsingReasoningFormat = false
                var initialContentBuffer = ""
                var isFirstChunk = true
                var responseContent = ""
                var currentThoughts: String? = nil
                var generationTimeSeconds: TimeInterval? = nil
                let hapticEnabled = SettingsManager.shared.hapticFeedbackEnabled
                var hapticGenerator: UIImpactFeedbackGenerator?
                var lastHapticTime = Date.distantPast
                let minHapticInterval: TimeInterval = 0.1
                let chunker = StreamingMarkdownChunker()
                let thinkingChunker = ThinkingTextChunker()
                var hapticChunkCount = 0
                var hasStartedResponse = false
                var lastUIUpdateTime = Date.distantPast
                let uiUpdateInterval: TimeInterval = 0.033

                await MainActor.run {
                    if let chat = self.currentChat,
                       !chat.messages.isEmpty,
                       let lastIndex = chat.messages.indices.last {
                        responseContent = chat.messages[lastIndex].content
                        currentThoughts = chat.messages[lastIndex].thoughts
                        generationTimeSeconds = chat.messages[lastIndex].generationTimeSeconds
                        isInThinkingMode = chat.messages[lastIndex].isThinking
                    }
                    if hapticEnabled {
                        hapticGenerator = UIImpactFeedbackGenerator(style: .light)
                        hapticGenerator?.prepare()
                    }
                }

                for try await chunk in stream {
                    if Task.isCancelled { break }

                    // Inline haptic feedback
                    if hapticEnabled, let generator = hapticGenerator {
                        if isInThinkingMode {
                            if hapticChunkCount < 5 {
                                let now = Date()
                                if now.timeIntervalSince(lastHapticTime) >= minHapticInterval {
                                    generator.impactOccurred(intensity: 0.5)
                                    lastHapticTime = now
                                    hapticChunkCount += 1
                                }
                            }
                        } else {
                            if !hasStartedResponse {
                                hasStartedResponse = true
                                hapticChunkCount = 0
                            }
                            if hapticChunkCount < 5 {
                                let now = Date()
                                if now.timeIntervalSince(lastHapticTime) >= minHapticInterval {
                                    generator.impactOccurred(intensity: 0.5)
                                    lastHapticTime = now
                                    hapticChunkCount += 1
                                }
                            }
                        }
                    }

                    let content = chunk.choices.first?.delta.content ?? ""
                    let hasReasoningContent = chunk.choices.first?.delta.reasoning != nil
                    let reasoningContent = chunk.choices.first?.delta.reasoning ?? ""
                    var didMutateState = false

                    // Collect sources from annotations (no deduplication to preserve citation index mapping)
                    if isWebSearchEnabled, let annotations = chunk.choices.first?.delta.annotations {
                        for annotation in annotations where annotation.type == "url_citation" {
                            if let citation = annotation.urlCitation {
                                let source = WebSearchSource(
                                    title: citation.title ?? citation.url,
                                    url: citation.url
                                )
                                collectedSources.append(source)
                                didMutateState = true
                            }
                        }
                    }

                    if hasReasoningContent && !isUsingReasoningFormat && !isInThinkingMode {
                        isUsingReasoningFormat = true
                        isInThinkingMode = true
                        isFirstChunk = false
                        thinkStartTime = Date()
                        thoughtsBuffer = reasoningContent
                        thinkingChunker.appendToken(reasoningContent)
                        currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                        didMutateState = true
                        // Reset summary service for new thinking session
                        Task { @MainActor in
                            ThinkingSummaryService.shared.reset()
                        }
                    } else if isUsingReasoningFormat {
                        if !reasoningContent.isEmpty {
                            thoughtsBuffer += reasoningContent
                            thinkingChunker.appendToken(reasoningContent)
                            currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                            isInThinkingMode = true
                            didMutateState = true
                            // Generate thinking summary (reuse existing client)
                            let currentThoughtsForSummary = thoughtsBuffer
                            let summaryClient = client
                            Task { @MainActor [weak self] in
                                ThinkingSummaryService.shared.generateSummary(thoughts: currentThoughtsForSummary, client: summaryClient) { summary in
                                    self?.thinkingSummary = summary
                                }
                            }
                        }

                        if !content.isEmpty && isInThinkingMode {
                            if let startTime = thinkStartTime {
                                generationTimeSeconds = Date().timeIntervalSince(startTime)
                            }
                            isInThinkingMode = false
                            thinkStartTime = nil
                            thinkingChunker.finalize()
                            currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                            // Clear thinking summary and cancel any in-flight summary generation
                            Task { @MainActor [weak self] in
                                ThinkingSummaryService.shared.reset()
                                self?.thinkingSummary = ""
                            }
                            // Inline appendToResponse
                            if responseContent.isEmpty {
                                responseContent = content
                            } else {
                                responseContent += content
                            }
                            chunker.appendToken(content)
                            didMutateState = true
                        } else if !content.isEmpty {
                            if responseContent.isEmpty {
                                responseContent = content
                            } else {
                                responseContent += content
                            }
                            chunker.appendToken(content)
                            isInThinkingMode = false
                            didMutateState = true
                        }
                    } else if !isUsingReasoningFormat && !content.isEmpty {
                        if isFirstChunk {
                            initialContentBuffer += content

                            if initialContentBuffer.contains("<think>") || initialContentBuffer.count > 5 {
                                isFirstChunk = false
                                let processContent = initialContentBuffer
                                initialContentBuffer = ""

                                if let thinkRange = processContent.range(of: "<think>") {
                                    isInThinkingMode = true
                                    hasThinkTag = true
                                    thinkStartTime = Date()
                                    let afterThink = String(processContent[thinkRange.upperBound...])
                                    thoughtsBuffer = afterThink
                                    thinkingChunker.appendToken(afterThink)
                                    currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                    didMutateState = true
                                    // Reset summary service for new thinking session
                                    Task { @MainActor in
                                        ThinkingSummaryService.shared.reset()
                                    }
                                } else {
                                    if responseContent.isEmpty {
                                        responseContent = processContent
                                    } else {
                                        responseContent += processContent
                                    }
                                    chunker.appendToken(processContent)
                                    didMutateState = true
                                }
                            }
                        } else if hasThinkTag {
                            if let endRange = content.range(of: "</think>") {
                                let beforeEnd = String(content[..<endRange.lowerBound])
                                thoughtsBuffer += beforeEnd
                                thinkingChunker.appendToken(beforeEnd)
                                thinkingChunker.finalize()
                                currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                isInThinkingMode = false
                                // Clear thinking summary and cancel any in-flight summary generation
                                Task { @MainActor [weak self] in
                                    ThinkingSummaryService.shared.reset()
                                    self?.thinkingSummary = ""
                                }

                                let afterEnd = String(content[endRange.upperBound...])
                                if responseContent.isEmpty {
                                    responseContent = afterEnd
                                } else {
                                    responseContent += afterEnd
                                }
                                chunker.appendToken(afterEnd)

                                if let startTime = thinkStartTime {
                                    generationTimeSeconds = Date().timeIntervalSince(startTime)
                                }

                                hasThinkTag = false
                                thinkStartTime = nil
                                thoughtsBuffer = ""
                                didMutateState = true
                            } else {
                                thoughtsBuffer += content
                                thinkingChunker.appendToken(content)
                                currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                isInThinkingMode = true
                                didMutateState = true
                                // Generate thinking summary (reuse existing client)
                                let currentThoughtsForSummary = thoughtsBuffer
                                let summaryClient = client
                                Task { @MainActor [weak self] in
                                    ThinkingSummaryService.shared.generateSummary(thoughts: currentThoughtsForSummary, client: summaryClient) { summary in
                                        self?.thinkingSummary = summary
                                    }
                                }
                            }
                        } else {
                            if responseContent.isEmpty {
                                responseContent = content
                            } else {
                                responseContent += content
                            }
                            chunker.appendToken(content)
                            didMutateState = true
                        }
                    }

                    // Update UI at a throttled rate to avoid overwhelming SwiftUI with diffs
                    let now = Date()
                    if didMutateState && now.timeIntervalSince(lastUIUpdateTime) >= uiUpdateInterval {
                        lastUIUpdateTime = now
                        let currentChunks = chunker.getAllChunks()
                        let currentThinkingChunks = thinkingChunker.getAllChunks()
                        let content = responseContent
                        let thoughts = currentThoughts
                        let thinking = isInThinkingMode
                        let genTime = generationTimeSeconds
                        let currentSources = collectedSources

                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard self.currentChat?.id == streamChatId else { return }
                            guard var chat = self.currentChat,
                                  chat.hasActiveStream,
                                  !chat.messages.isEmpty,
                                  let lastIndex = chat.messages.indices.last else {
                                return
                            }

                            // Process citations during streaming if we have sources
                            let processedContent = self.processCitationMarkers(content, sources: currentSources)
                            let processedChunks = self.processChunksWithCitations(currentChunks, sources: currentSources)

                            chat.messages[lastIndex].content = processedContent
                            chat.messages[lastIndex].thoughts = thoughts
                            chat.messages[lastIndex].thinkingChunks = currentThinkingChunks
                            chat.messages[lastIndex].isThinking = thinking
                            chat.messages[lastIndex].generationTimeSeconds = genTime
                            chat.messages[lastIndex].contentChunks = processedChunks

                            // Merge collected sources into the message's current webSearchState (set by the callback)
                            if !currentSources.isEmpty {
                                var searchState = chat.messages[lastIndex].webSearchState ?? WebSearchState(status: .searching)
                                searchState.sources = currentSources
                                chat.messages[lastIndex].webSearchState = searchState
                            }

                            self.updateChat(chat, throttleForStreaming: true)
                        }
                    }
                }

                // Handle any remaining content when stream ends
                if isInThinkingMode && !thoughtsBuffer.isEmpty {
                    if isUsingReasoningFormat {
                        currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                    } else {
                        currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                        if responseContent.isEmpty {
                            responseContent = thoughtsBuffer
                            currentThoughts = nil
                        }
                    }
                    if let startTime = thinkStartTime {
                        generationTimeSeconds = Date().timeIntervalSince(startTime)
                    }
                    isInThinkingMode = false
                } else if isFirstChunk && !initialContentBuffer.isEmpty {
                    if responseContent.isEmpty {
                        responseContent = initialContentBuffer
                    } else {
                        responseContent += initialContentBuffer
                    }
                    _ = chunker.appendToken(initialContentBuffer)
                    isInThinkingMode = false
                    currentThoughts = nil
                }

                // Finalize message content and prepare chat for save
                // Look up the streaming chat by ID, not self.currentChat, because
                // the user may have navigated away or toggled sync mid-stream.
                var finalizedChat: Chat? = await MainActor.run {
                    self.isLoading = false

                    guard let sid = streamChatId,
                          let location = self.findChatLocation(sid) else { return nil }
                    var chat = location.isLocal ? self.localChats[location.index] : self.chats[location.index]
                    chat.hasActiveStream = false

                    self.streamUpdateTimer?.invalidate()
                    self.streamUpdateTimer = nil
                    if let pending = self.pendingStreamUpdate {
                        self.pendingStreamUpdate = nil
                        if self.hasChatAccess {
                            self.saveChat(pending)
                        }
                    }

                    // Finalize all message content
                    ThinkingSummaryService.shared.reset()
                    self.thinkingSummary = ""
                    self.webSearchSummary = ""
                    if !chat.messages.isEmpty, let lastIndex = chat.messages.indices.last {
                        chunker.finalize()
                        thinkingChunker.finalize()
                        let processedContent = self.processCitationMarkers(responseContent, sources: collectedSources)
                        chat.messages[lastIndex].content = processedContent
                        chat.messages[lastIndex].thoughts = currentThoughts
                        chat.messages[lastIndex].thinkingChunks = thinkingChunker.getAllChunks()
                        chat.messages[lastIndex].isThinking = false
                        chat.messages[lastIndex].generationTimeSeconds = generationTimeSeconds
                        // Process citation markers in chunks too since UI renders from chunks
                        let processedChunks = self.processChunksWithCitations(chunker.getAllChunks(), sources: collectedSources)
                        chat.messages[lastIndex].contentChunks = processedChunks
                        // Merge final collected sources into the message's webSearchState
                        if !collectedSources.isEmpty {
                            var searchState = chat.messages[lastIndex].webSearchState ?? WebSearchState(status: .searching)
                            searchState.sources = collectedSources
                            chat.messages[lastIndex].webSearchState = searchState
                        }
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

                // Single save + cloud sync with the resolved title
                await MainActor.run {
                    if let chat = finalizedChat {
                        self.updateChat(chat)
                        self.endStreamingAndBackup(chatId: chat.id)
                    }
                }
            } catch {
                // Check if this is a 401 auth error and we haven't retried yet
                let shouldRetry = await MainActor.run {
                    if !hasRetriedWithFreshKey && self.isAuthenticationError(error) {
                        return true
                    }
                    return false
                }

                if shouldRetry {
                    hasRetriedWithFreshKey = true
                    await self.refreshClientForRetry()
                    if await MainActor.run(body: { self.client != nil }) {
                        continue retryLoop
                    }
                }

                // Handle error
                await MainActor.run {
                    self.isLoading = false
                    self.thinkingSummary = ""
                    self.webSearchSummary = ""

                    // Mark the chat as no longer having an active stream
                    // Look up by streamChatId, not self.currentChat, in case user navigated away
                    if let sid = streamChatId,
                       let location = self.findChatLocation(sid) {
                        var chat = location.isLocal ? self.localChats[location.index] : self.chats[location.index]
                        chat.hasActiveStream = false

                        // Force any pending stream updates to save immediately
                        self.streamUpdateTimer?.invalidate()
                        self.streamUpdateTimer = nil
                        if let pending = self.pendingStreamUpdate {
                            self.pendingStreamUpdate = nil
                            if self.hasChatAccess {
                                self.saveChat(pending)
                            }
                        }

                        self.updateChat(chat)  // Final update without throttling

                        self.endStreamingAndBackup(chatId: chat.id)
                    }

                    if let sid = streamChatId,
                       let location = self.findChatLocation(sid) {
                        var chat = location.isLocal ? self.localChats[location.index] : self.chats[location.index]
                        if !chat.messages.isEmpty {
                            let lastIndex = chat.messages.count - 1

                            // Format a more user-friendly error message based on the error type
                            let userFriendlyError = formatUserFriendlyError(error)

                            // Set the stream error - the ErrorMessageView will display it nicely
                            // Keep any partial content that was received
                            chat.messages[lastIndex].streamError = userFriendlyError

                            self.updateChat(chat)
                        }
                    }
                }
            }
        }
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
        
        // Server issues
        if let httpResponse = nsError.userInfo[NSUnderlyingErrorKey] as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 500...599:
                return "Server error. Our team has been notified and is working on it."
            case 429:
                return "Rate limit exceeded. Please wait a moment before sending another message."
            default:
                break
            }
        }
        
        // Default error message if nothing specific matches
        return "An error occurred: \(error.localizedDescription)"
    }

    /// Checks if an error is an authentication error (401)
    private func isAuthenticationError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == "TinfoilChat" && nsError.code == 401 {
            return true
        }

        if let httpResponse = nsError.userInfo[NSUnderlyingErrorKey] as? HTTPURLResponse,
           httpResponse.statusCode == 401 {
            return true
        }

        return false
    }

    /// Refreshes the API key and recreates the client
    private func refreshClientForRetry() async {
        APIKeyManager.shared.clearApiKey()
        setupTinfoilClient()

        // Wait for client initialization to complete
        let maxWaitTime = Constants.Sync.clientInitTimeoutSeconds
        let startTime = Date()
        while isClientInitializing && Date().timeIntervalSince(startTime) < maxWaitTime {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    /// Cancels the current message generation
    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        thinkingSummary = ""
        webSearchSummary = ""

        // Reset the hasActiveStream property
        if var chat = currentChat {
            chat.hasActiveStream = false
            updateChat(chat)
            // End streaming tracking for cloud sync
            streamingTracker.endStreaming(chat.id)
        }

        self.showVerifierSheet = false
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

        isLoading = true

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
        scrollToBottomTrigger = UUID()

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
    
    // MARK: - Private Methods

    private func endStreamingAndBackup(chatId: String) {
        guard authManager?.isAuthenticated == true else { return }

        streamingTracker.endStreaming(chatId)

        guard let location = findChatLocation(chatId) else {
            return
        }
        let latestChat = location.isLocal ? localChats[location.index] : chats[location.index]
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
        // Track if currentChat was pointing to a blank chat
        let wasCurrentChatBlank = currentChat?.isBlankChat == true

        // Step 1: Remove ALL blank chats to deduplicate
        var normalizedChats = chats.filter { !$0.isBlankChat }

        // Step 2: Deduplicate by ID (keep first occurrence, preserve order)
        var seenIds = Set<String>()
        normalizedChats = normalizedChats.filter { chat in
            if seenIds.contains(chat.id) {
                return false
            }
            seenIds.insert(chat.id)
            return true
        }

        // Step 3: Add exactly ONE blank chat at position 0 if user has chat access
        var newBlankChat: Chat?
        if hasChatAccess {
            let blankChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId
            )
            normalizedChats.insert(blankChat, at: 0)
            newBlankChat = blankChat
        }

        // Update the chats array
        chats = normalizedChats

        // Step 4: If currentChat was pointing to a blank chat, update it to the new blank chat
        // This maintains the invariant that currentChat is always in the chats array
        if wasCurrentChatBlank, let newBlankChat = newBlankChat {
            currentChat = newBlankChat
        }
    }

    /// Normalizes the localChats array: deduplicates and ensures one blank chat at top
    private func normalizeLocalChatsArray() {
        let wasCurrentChatLocalBlank = currentChat?.isBlankChat == true && currentChat?.isLocalOnly == true

        var normalized = localChats.filter { !$0.isBlankChat }
        var seenIds = Set<String>()
        normalized = normalized.filter { chat in
            if seenIds.contains(chat.id) { return false }
            seenIds.insert(chat.id)
            return true
        }

        var newBlankChat: Chat?
        if hasChatAccess {
            let blankChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId,
                isLocalOnly: true
            )
            normalized.insert(blankChat, at: 0)
            newBlankChat = blankChat
        }

        localChats = normalized

        if wasCurrentChatLocalBlank, let newBlankChat = newBlankChat {
            currentChat = newBlankChat
        }
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
        if chat.hasActiveStream || isLoading {
            updatedChat.locallyModified = true
            updatedChat.updatedAt = Date()
        }
        
        replaceChat(updatedChat)
        let chatFound = localChats.contains(where: { $0.id == chat.id }) || chats.contains(where: { $0.id == chat.id })
        if chatFound {
            // Update currentChat directly ONLY IF it's the one being updated
            if currentChat?.id == chat.id {
                currentChat = updatedChat
            }

            // During streaming, batch saves to reduce disk I/O
            if throttleForStreaming {
                // Store pending update
                pendingStreamUpdate = updatedChat

                // Cancel existing timer and create new one
                streamUpdateTimer?.invalidate()
                streamUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        if let pending = self?.pendingStreamUpdate {
                            self?.pendingStreamUpdate = nil
                            if self?.hasChatAccess == true {
                                self?.saveChat(pending)
                            }
                        }
                    }
                }
            } else {
                // Save immediately for non-streaming updates
                if hasChatAccess {
                    saveChat(updatedChat)
                }
            }
        } else {
            // Chat not found in array - this shouldn't happen but handle it
            if updatedChat.isLocalOnly {
                localChats.insert(updatedChat, at: 0)
            } else {
                chats.insert(updatedChat, at: 0)
            }

            // Update currentChat if it's the one being updated
            if currentChat?.id == chat.id {
                currentChat = updatedChat
            }

            // IMPORTANT: Preserve pagination state when inserting new chats
            // Adding a new chat doesn't affect whether more chats are available to load
            // The hasMoreChats flag should remain unchanged

            // Save chats for all authenticated users
            if hasChatAccess {
                saveChat(updatedChat)
            }
        }
    }
    
    /// Saves a single chat to per-chat file storage and triggers cloud backup
    private func saveChat(_ chat: Chat) {
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
        if SettingsManager.shared.isCloudSyncEnabled && !chat.isLocalOnly && !chat.messages.isEmpty && !chat.hasActiveStream {
            let saveTask = pendingSaveTask
            Task {
                await saveTask?.value
                await cloudSync.backupChat(chat.id)
            }
        }
    }
    
    
    // MARK: - Model Management
    
    /// Changes the current model and re-initializes the Tinfoil client
    func changeModel(to modelType: ModelType, shouldUpdateChat: Bool = true) {
        // Only proceed if the model is actually changing
        guard modelType != currentModel else { return }
        
        // Cancel any ongoing tasks
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        
        // Check if we need a premium key for this model
        let isPremiumModel = !modelType.isFree
        
        // If switching to premium model, verify authentication and subscription
        if isPremiumModel {
            let isAuthenticated = authManager?.isAuthenticated ?? false
            let hasSubscription = authManager?.hasActiveSubscription ?? false
            
            // Show warning if user is not authenticated or doesn't have subscription
            if !isAuthenticated || !hasSubscription {
                self.verification.error = isAuthenticated 
                    ? "Premium model requires an active subscription." 
                    : "Premium model requires authentication."
                
                // Don't proceed with model change if not authorized
                return
            }
        }
        
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
            // Clear cached API key and reinitialize client only when auth changes
            APIKeyManager.shared.clearApiKey()
            setupTinfoilClient()
        }

        // Get available models based on auth status
        let availableModels = AppConfig.shared.filteredModelTypes(
            isAuthenticated: isAuthenticated,
            hasActiveSubscription: hasActiveSubscription
        )
        
        // If current model is not available, switch to first available model
        if !availableModels.contains(where: { $0.id == currentModel.id }), let firstModel = availableModels.first {
            changeModel(to: firstModel)
        }
        
        
        // If user upgraded to premium, load saved chats if any
        if isAuthenticated && hasActiveSubscription && chats.count <= 1 {
            Task {
                let result = await loadFirstPageOfChats(userId: currentUserId, filter: { !$0.isLocalOnly })
                guard !result.chats.isEmpty else { return }
                let previouslySelectedId = self.currentChat?.id
                self.chats = result.chats

                // Preserve existing selection when possible so we don't jump to a blank chat
                if let chatId = previouslySelectedId,
                   let location = self.findChatLocation(chatId) {
                    self.currentChat = location.isLocal ? self.localChats[location.index] : self.chats[location.index]
                } else if self.currentChat == nil {
                    self.currentChat = self.chats.first
                }

                self.ensureBlankChatAtTop()
            }
        }
    }
    
    /// Handle sign-out by clearing current chats but preserving them in storage
    func handleSignOut() {
        // Allow a new sign-in flow after sign-out
        isSignInInProgress = false
        hasPerformedInitialSync = false

        // Stop auto-sync timer when signing out
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
        
        // Save current chat before clearing (it's already associated with the user ID)
        if hasChatAccess, let chat = currentChat {
            saveChat(chat)
        }
        
        // Clear sync caches so stale state doesn't leak into the next session
        cloudSync.clearSyncStatus()
        DeletedChatsTracker.shared.clear()
        
        // Reset to a free model when signing out
        let freeModels = AppConfig.shared.filteredModelTypes(
            isAuthenticated: false,
            hasActiveSubscription: false
        )
        if let defaultFreeModel = freeModels.first {
            currentModel = defaultFreeModel
            AppConfig.shared.currentModel = defaultFreeModel
        }
        
        // Reset pagination state when signing out
        paginationToken = nil
        hasMoreChats = false
        isPaginationActive = false
        hasLoadedInitialPage = false
        hasAttemptedLoadMore = false
        
        // Clear current chats and create a new empty one with the free model
        chats = []
        localChats = []
        activeStorageTab = .cloud
        let newChat = Chat.create(modelType: currentModel)
        currentChat = newChat
        chats = [newChat]
        
    }
    
    /// Clear all local chats and reset to fresh state
    func clearAllLocalChats() {
        // Clear all chats from memory
        chats.removeAll()
        localChats.removeAll()
        currentChat = nil
        
        // Clear from file storage
        let userId = currentUserId
        Task {
            await Chat.deleteAllChatsFromStorage(userId: userId)
        }
        
        // Reset sync state
        lastSyncDate = nil
        syncErrors = []
        isSyncing = false
        
        // Reset pagination state
        paginationToken = nil
        hasMoreChats = false
        isPaginationActive = false
        hasLoadedInitialPage = false
        hasAttemptedLoadMore = false
        
        // Clear encryption key reference
        encryptionKey = nil
    }
    
    /// Handle sign-in by loading user's saved chats and triggering sync
    func handleSignIn() {
        #if DEBUG
        print("handleSignIn called")
        #endif

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
                        self.activeStorageTab = .local
                        normalizeLocalChatsArray()
                        if self.currentChat == nil, let first = self.localChats.first {
                            self.currentChat = first
                        }
                    }

                    // If no cloud key exists yet, let ContentView present the prompt and stop here
                    if !EncryptionService.shared.hasEncryptionKey() {
                        await MainActor.run {
                            self.isFirstTimeUser = true
                            self.isSignInInProgress = false
                        }
                        return
                    }

                    // Initialize encryption - this will load existing key from keychain
                    let key = try await EncryptionService.shared.initialize()
                    self.encryptionKey = key

                    // Retry decryption for any previously failed chats now that key is loaded
                    let decryptedCount = await cloudSync.retryDecryptionWithNewKey(onProgress: nil)
                    if decryptedCount > 0 {
                        let result = await loadFirstPageOfChats(userId: self.currentUserId, filter: { !$0.isLocalOnly })
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
                        // Force all local chats to be marked for sync
                        if let userId = self.currentUserId {
                            let allChats = await Chat.loadAllChats(userId: userId)
                            for var chat in allChats {
                                chat.locallyModified = true
                                chat.syncVersion = 0
                                await Chat.saveChat(chat, userId: userId)
                            }
                        }
                        self.hasAnonymousChatsToSync = false
                    }

                    // Local chats were already loaded above the early return.

                    // Only proceed with cloud sync if cloud sync is enabled
                    if SettingsManager.shared.isCloudSyncEnabled {
                        await initializeCloudSync()
                        
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
            .sorted { $0.createdAt > $1.createdAt }
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
            .sorted { $0.createdAt > $1.createdAt }
        let firstPageIds = filtered.prefix(Constants.Pagination.chatsPerPage).map(\.id)

        let chats = await Chat.loadChats(chatIds: firstPageIds, userId: userId)
            .sorted { $0.createdAt > $1.createdAt }

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
        let result = await loadFirstPageOfChats(userId: userId, excluding: locallyModifiedIds, filter: { !$0.isLocalOnly })

        // Combine: locally modified chats + synced chats from files
        let sortedChats = (locallyModifiedChats + result.chats).sorted { $0.createdAt > $1.createdAt }

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
        
        // Sort non-blank chats by createdAt before normalization
        updatedChats.sort { chat1, chat2 in
            if chat1.isBlankChat { return true }
            if chat2.isBlankChat { return false }
            return chat1.createdAt > chat2.createdAt
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
        if result.downloaded > 0 || result.uploaded > 0 {
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
    
    /// Set encryption key (for key rotation)
    func setEncryptionKey(_ key: String) async throws {
        do {
            let oldKey = EncryptionService.shared.getKey()
            try await EncryptionService.shared.setKey(key)
            
            await MainActor.run {
                self.encryptionKey = key
                self.showEncryptionSetup = false
            }
            
            // If key changed, handle re-encryption
            if oldKey != key {
                
                // Show syncing indicator while processing
                await MainActor.run {
                    self.isSyncing = true
                }
                
                // Retry decryption with new key
                let decryptedCount = await cloudSync.retryDecryptionWithNewKey { current, total in
                    Task { @MainActor in
                        // Could add progress tracking here if needed
                    }
                }
                
                // Reload chats immediately after decryption to show decrypted chats
                if decryptedCount > 0 {
                    let result = await loadFirstPageOfChats(userId: self.currentUserId, filter: { !$0.isLocalOnly })
                    await MainActor.run {
                        self.chats = result.chats
                        normalizeChatsArray()
                    }
                }
                
                // Re-encrypt and upload all chats in background
                let _ = await cloudSync.reencryptAndUploadChats()
                
                // Perform full sync
                await performFullSync()
                
                // Hide syncing indicator
                await MainActor.run {
                    self.isSyncing = false
                    self.lastSyncDate = Date()
                }
            }
            
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
        let result = await loadFirstPageOfChats(userId: currentUserId, filter: { !$0.isLocalOnly })
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

        // Look for a title generation model
        let allModelTypes = AppConfig.shared.appModels.map { ModelType(from: $0) }
        guard let titleModel = allModelTypes.first(where: { $0.type == "title" }) else {
            return nil
        }

        // Truncate content to word threshold
        let words = assistantMessage.content.split(separator: " ", omittingEmptySubsequences: true)
        let truncatedContent = words
            .prefix(Constants.TitleGeneration.wordThreshold)
            .joined(separator: " ")

        // Ensure client is available
        if client == nil {
            setupTinfoilClient()
            let maxWait: TimeInterval = Constants.Sync.clientInitTimeoutSeconds
            let start = Date()
            while client == nil && Date().timeIntervalSince(start) < maxWait {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard let client else { return nil }

        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent(Constants.TitleGeneration.systemPrompt))),
                .user(.init(content: .string(truncatedContent)))
            ],
            model: titleModel.modelName,
        )

        do {
            let result: ChatResult = try await client.chats(query: query)
            let title = result.choices.first?.message.content ?? ""

            let cleanTitle = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[\"']|[\"']$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanTitle.isEmpty else {
                return nil
            }
            return cleanTitle
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
            audioError = error.localizedDescription
            return nil
        }
    }

    /// Cancel recording without transcribing
    func cancelAudioRecording() {
        isRecording = false
        AudioRecordingService.shared.cancelRecording()
    }

    private func processChunksWithCitations(_ chunks: [ContentChunk], sources: [WebSearchSource]) -> [ContentChunk] {
        chunks.map { chunk in
            ContentChunk(
                id: chunk.id,
                type: chunk.type,
                content: processCitationMarkers(chunk.content, sources: sources),
                isComplete: chunk.isComplete
            )
        }
    }

    /// Process citation markers (e.g. 【1】) into markdown links.
    /// Called at stream end to store processed content.
    private func processCitationMarkers(_ content: String, sources: [WebSearchSource]) -> String {
        guard !sources.isEmpty else { return content }

        let pattern = "【(\\d+)[^】]*】"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return content
        }

        let nsContent = content as NSString
        var result = content
        var offset = 0

        let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let numRange = Range(match.range(at: 1), in: content),
                  let num = Int(content[numRange]) else { continue }

            let index = num - 1
            guard index >= 0, index < sources.count else { continue }

            let source = sources[index]

            let encodedUrl = source.url
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
                .replacingOccurrences(of: "|", with: "%7C")
                .replacingOccurrences(of: "~", with: "%7E")
            let encodedTitle = (source.title
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source.title)
                .replacingOccurrences(of: "~", with: "%7E")

            let replacement = "[\(num)](#cite-\(num)~\(encodedUrl)~\(encodedTitle))"

            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            if let swiftRange = Range(adjustedRange, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
                offset += replacement.count - match.range.length
            }
        }

        return result
    }
}
