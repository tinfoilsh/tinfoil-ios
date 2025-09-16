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

@MainActor
class ChatViewModel: ObservableObject {
    // Published properties for UI updates
    @Published var chats: [Chat] = []
    @Published var currentChat: Chat?
    @Published var isLoading: Bool = false
    @Published var showVerifierSheet: Bool = false
    @Published var scrollTargetMessageId: String? = nil 
    @Published var scrollTargetOffset: CGFloat = 0 
    /// When set to true, the input field should become first responder (focus keyboard)
    @Published var shouldFocusInput: Bool = false
    
    // Verification properties - consolidated to reduce update frequency
    struct VerificationInfo {
        var isVerifying: Bool = false
        var isVerified: Bool = false
        var error: String? = nil
    }
    @Published var verification = VerificationInfo()
    private var hasRunInitialVerification: Bool = false
    
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
    @Published var showMigrationPrompt: Bool = false
    @Published var userAgreedToMigrateLegacy: Bool = false
    @Published var shouldShowKeyImport: Bool = false
    private let cloudSync = CloudSyncService.shared
    private let streamingTracker = StreamingTracker.shared
    private var isSignInInProgress: Bool = false  // Prevent duplicate sign-in flows
    private var hasPerformedInitialSync: Bool = false  // Track if initial sync has been done
    private var hasAnonymousChatsToSync: Bool = false  // Track if we have anonymous chats to sync
    private var isMigrationDecisionPending: Bool = false
    
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
    
    // Stored verification measurements
    private var verificationCodeDigest: String?
    private var verificationRuntimeDigest: String?
    private var verificationTlsCertFingerprint: String?
    
    // Model properties
    @Published var currentModel: ModelType
    
    // View state for verifier
    @Published var verifierView: VerifierView?
    
    
    // Speech-to-text properties
    @Published var isRecording: Bool = false
    @Published var transcribedText: String = ""
    
    // Audio recording properties
    private var audioRecorder: AVAudioRecorder?
    private var audioSession: AVAudioSession = AVAudioSession.sharedInstance()
    private var recordingURL: URL?
    
    // Private properties
    private var client: OpenAI?
    private var currentTask: Task<Void, Error>?
    private var autoSyncTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
    private var streamUpdateTimer: Timer?
    private var pendingStreamUpdate: Chat?
    
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
            }
        }
    }
    
    var messages: [Message] { // This now holds all messages for the current chat
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
    
    // Computed property to check if speech-to-text is available
    var hasSpeechToTextAccess: Bool {
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
            return "Verification in progress..."
        } else if isVerified {
            return "Verified. This chat is private."
        } else if let error = verificationError {
            return "Verification failed: \(error)"
        } else {
            return "Verification needed"
        }
    }
    
    init(authManager: AuthManager? = nil) {
        // Initialize with last selected model from AppConfig (which now persists)
        self.currentModel = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first!
        
        // Load persisted last sync date (will be loaded per-user when auth is set)
        // Initial load happens in the authManager didSet
        
        // Store auth manager reference (will trigger initial sync via didSet if authenticated)
        self.authManager = authManager
        
        // Always create a new chat when the app is loaded initially
        if let auth = authManager, auth.isAuthenticated {
            // Create a temporary blank chat for immediate display
            let newChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId
            )
            chats = [newChat]
            currentChat = newChat
            
            // Reset pagination state for fresh app start
            // Don't wipe persisted values here; let restoration happen via loadPersistedPaginationState()
        } else {
            // For non-authenticated users, just create a single chat without saving
            let newChat = Chat.create(modelType: currentModel)
            currentChat = newChat
            chats = [newChat]
        }
        
        // Load any previously persisted pagination state (per-user)
        // Delay enabling persistence until after load to avoid overwriting saved values
        loadPersistedPaginationState()

        // Setup app lifecycle observers
        setupAppLifecycleObservers()
        
        // If app opens and user is already signed in, check legacy data immediately
        if authManager?.isAuthenticated == true {
            if CloudMigrationService.shared.isMigrationNeeded(userId: currentUserId) {
                // Gate all sync until the user decides
                self.isMigrationDecisionPending = true
                self.showMigrationPrompt = true
            }
        }
        
        // Initial sync will be triggered when authManager is set (see authManager didSet)
    }
    
    deinit {
        // Stop auto-sync timer
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
        
        // Stop stream update timer
        streamUpdateTimer?.invalidate()
        streamUpdateTimer = nil
        
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
        
        // Do not start auto-sync until user decides how to handle legacy data
        if isMigrationDecisionPending {
            return
        }
        
        
        // Create timer that fires at regular intervals
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: Constants.Sync.autoSyncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Gate auto-sync if migration decision is pending
                if self.isMigrationDecisionPending {
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
                    // Sync all chats
                    let syncResult = await self.cloudSync.syncAllChats()
                    
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
                           let chat = self.chats.first(where: { $0.id == currentChatId }) {
                            self.currentChat = chat
                        }
                        
                    }
                    
                    // Also backup current chat if it has changes
                    if let currentChat = await MainActor.run(body: { self.currentChat }),
                       !currentChat.hasTemporaryId,
                       !currentChat.messages.isEmpty,
                       !currentChat.hasActiveStream {
                        try await self.cloudSync.backupChat(currentChat.id)
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
            
            // Resume auto-sync timer if authenticated
            Task { @MainActor in
                if self?.authManager?.isAuthenticated == true {
                    // Skip any sync activity while migration decision is pending
                    if self?.isMigrationDecisionPending == true {
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
                if self?.authManager?.isAuthenticated == true {
                    // Do not perform background sync if migration decision is pending
                    if self?.isMigrationDecisionPending == true {
                        return
                    }
                    if let _ = await self?.cloudSync.syncAllChats() {
                        // Update last sync date
                        self?.lastSyncDate = Date()
                    }
                }
            }
        }
    }
    
    private func setupTinfoilClient() {
        if !hasRunInitialVerification {
            self.verification.error = nil
            self.verification.isVerifying = true
        }
        
        Task {
            do {
                // Wait for AppConfig to be ready before getting API key
                await AppConfig.shared.waitForInitialization()
                
                // Get the global API key (can be empty for free models)
                let apiKey = await AppConfig.shared.getApiKey()
                
                if !hasRunInitialVerification {
                    // Run explicit verification first to capture measurements
                    await runExplicitVerification()
                    
                    // Then create the client with nonblocking verification as a double check
                    client = try await TinfoilAI.create(
                        apiKey: apiKey,
                        nonblockingVerification: { [weak self] passed in
                            Task { @MainActor in
                                guard let self = self else { return }
                                
                                // Update verification state if there's a mismatch
                                if !passed && self.verification.isVerified {
                                    self.verification.isVerified = false
                                    self.verification.error = "Client verification failed after explicit verification succeeded"
                                }
                            }
                        }
                    )
                } else {
                    client = try await TinfoilAI.create(
                        apiKey: apiKey,
                        nonblockingVerification: nil
                    )
                }

            } catch {
                if !hasRunInitialVerification {
                    self.verification.isVerifying = false
                    self.verification.isVerified = false
                    self.verification.error = error.localizedDescription
                    self.hasRunInitialVerification = true
                }
            }
        }
    }
    
    /// Runs explicit verification and stores measurements
    private func runExplicitVerification() async {
        // Create callbacks to capture verification results
        let callbacks = VerificationCallbacks(
            onVerificationStart: { [weak self] in
                Task { @MainActor in
                    self?.verification.isVerifying = true
                }
            },
            onVerificationComplete: { [weak self] result in
                Task { @MainActor in
                    guard let self = self else { return }
                    
                    self.verification.isVerifying = false
                    self.hasRunInitialVerification = true
                    
                    switch result {
                    case .success(let groundTruth):
                        // Store measurements from ground truth
                        // Always try to format measurements, even if not in expected format
                        
                        // Handle code measurement - extract first register value
                        if let codeMeasurement = groundTruth.codeMeasurement {
                            self.verificationCodeDigest = codeMeasurement.registers.first ?? ""
                        }
                        
                        // Handle enclave measurement - extract first register value
                        if let enclaveMeasurement = groundTruth.enclaveMeasurement {
                            self.verificationRuntimeDigest = enclaveMeasurement.registers.first ?? ""
                        }
                        
                        // Store the public key (this is already a string)
                        self.verificationTlsCertFingerprint = groundTruth.publicKeyFP
                        
                        self.verification.isVerified = true
                        self.verification.error = nil
                        
                    case .failure(let error):
                        self.verification.isVerified = false
                        self.verification.error = error.localizedDescription
                    }
                }
            }
        )
        
        // Create secure client and run verification
        let secureClient = SecureClient(
            githubRepo: Constants.Proxy.githubRepo,
            enclaveURL: Constants.Proxy.enclaveURL,
            callbacks: callbacks
        )
        
        do {
            _ = try await secureClient.verify()
        } catch {
            await MainActor.run {
                self.verification.isVerifying = false
                self.verification.isVerified = false
                self.verification.error = error.localizedDescription
                self.hasRunInitialVerification = true
            }
        }
    }
    
    /// Public method to retry client setup (called when returning from background)
    func retryClientSetup() {
        // Only retry if we don't have a working client or if verification actually failed
        // Don't recreate the client unnecessarily as it causes temporary verification failures
        guard client == nil || (!isVerified && !isVerifying && verificationError != nil) else {
            // Client exists and is either verified or still verifying - no need to recreate
            return
        }
        
        // Don't reset client while there's an active message being sent
        guard !isLoading else {
            // Retry after the current operation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retryClientSetup()
            }
            return
        }
        
        setupTinfoilClient()
    }
    
    // MARK: - Public Methods
    
    /// Creates a new chat and sets it as the current chat
    func createNewChat(language: String? = nil, modelType: ModelType? = nil) {
        // Allow creating new chats for all authenticated users
        guard hasChatAccess else { return }
        
        // Cancel any ongoing generation first
        if isLoading {
            cancelGeneration()
        }
        
        // Check if we already have a blank chat at the top
        if let firstChat = chats.first, firstChat.isBlankChat {
            // Just select the existing blank chat
            selectChat(firstChat)
            if !isMigrationDecisionPending && EncryptionService.shared.hasEncryptionKey() {
                shouldFocusInput = true
            }
            return
        }
        
        // Create new chat with temporary ID (instant, no network call)
        // The chat will automatically be blank (no messages) and have a temporary ID (UUID)
        let newChat = Chat.create(
            modelType: modelType ?? currentModel,
            language: language,
            userId: currentUserId
        )
        
        chats.insert(newChat, at: 0)
        selectChat(newChat)
        if !isMigrationDecisionPending && EncryptionService.shared.hasEncryptionKey() {
            shouldFocusInput = true
        }
        
        // Preserve pagination state - adding a blank chat doesn't affect whether more chats are available
        // The hasMoreChats flag should remain unchanged
    }
    
    /// Selects a chat as the current chat
    func selectChat(_ chat: Chat) {
        
        // Cancel any ongoing generation first
        if isLoading {
            cancelGeneration()
        }
        
        // Find the most up-to-date version of the chat in the chats array
        let chatToSelect: Chat
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chatToSelect = chats[index]
        } else {
            chatToSelect = chat
            if !chats.contains(where: { $0.id == chat.id }) {
                chats.append(chatToSelect) // Add if truly new
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
        
        if let index = chats.firstIndex(where: { $0.id == id }) {
            let deletedChat = chats.remove(at: index)
            
            // Mark as deleted for cloud sync
            DeletedChatsTracker.shared.markAsDeleted(id)
            
            // If the deleted chat was the current chat, select another one
            if currentChat?.id == deletedChat.id {
                currentChat = chats.first
            }
            
            saveChats()
            
            // Delete from cloud
            Task {
                do {
                    try await cloudSync.deleteFromCloud(id)
                } catch {
                }
            }
        }
    }
    
    /// Updates a chat's title
    func updateChatTitle(_ id: String, newTitle: String) {
        // Allow updating chat titles for all authenticated users
        guard hasChatAccess else { return }
        
        if let index = chats.firstIndex(where: { $0.id == id }) {
            var updatedChat = chats[index]
            let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                updatedChat.title = Chat.placeholderTitle
                updatedChat.titleState = .placeholder
            } else {
                updatedChat.title = newTitle
                updatedChat.titleState = .manual
            }
            updatedChat.locallyModified = true
            updatedChat.updatedAt = Date()
            chats[index] = updatedChat
            if currentChat?.id == id {
                currentChat = updatedChat
            }
            saveChats()
        }
    }
    
    /// Sends a user message and generates a response
    func sendMessage(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        // Update UI state  
        isLoading = true
        
        // Create and add user message
        let userMessage = Message(role: .user, content: text)
        addMessage(userMessage)
        
        // If this is the first message, update creation date (title will be generated after assistant reply)
        if var chat = currentChat, chat.messages.count == 1 {
            // Update creation date to now (when first message is sent)
            chat.createdAt = Date()
            chat.updatedAt = Date()
            chat.locallyModified = true  // Ensure it's marked as modified
            // Keep placeholder title for now; generate via LLM after first assistant response
            updateChat(chat)
        }
        
        // Create initial empty assistant message as a placeholder
        let assistantMessage = Message(role: .assistant, content: "")
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
            
            do {
                // Wait for client initialization if needed
                if client == nil {
                    setupTinfoilClient()
                    
                    // Wait for client to be available with timeout
                    let maxWaitTime = Constants.Sync.clientInitTimeoutSeconds
                    let startTime = Date()
                    
                    while client == nil && Date().timeIntervalSince(startTime) < maxWaitTime {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    }
                }
                
                guard let client = client else {
                    throw NSError(domain: "TinfoilChat", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Service temporarily unavailable. Please try again."])
                }
                
                // Create the stream with proper parameters
                let modelId = AppConfig.shared.getModelConfig(currentModel)?.modelId ?? ""
                
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
                
                // Append rules if they exist
                let rules = AppConfig.shared.rules
                if !rules.isEmpty {
                    // Apply same replacements to rules
                    var processedRules = rules.replacingOccurrences(of: "{MODEL_NAME}", with: currentModel.fullName)
                    
                    // Use the same language that was used for the system prompt
                    processedRules = processedRules.replacingOccurrences(of: "{LANGUAGE}", with: languageToUse)
                    
                    if !personalizationXML.isEmpty {
                        processedRules = processedRules.replacingOccurrences(of: "{USER_PREFERENCES}", with: personalizationXML)
                    } else {
                        processedRules = processedRules.replacingOccurrences(of: "{USER_PREFERENCES}", with: "")
                    }
                    
                    processedRules = processedRules.replacingOccurrences(of: "{CURRENT_DATETIME}", with: currentDateTime)
                    processedRules = processedRules.replacingOccurrences(of: "{TIMEZONE}", with: timezone)
                    
                    systemPrompt += "\n" + processedRules
                }
                
                // Build messages array inline
                var messages: [ChatQuery.ChatCompletionMessageParam] = [
                    .system(.init(content: .textContent(systemPrompt)))
                ]
                
                // Add conversation messages - use ProfileManager's maxPromptMessages if available
                let maxMessages = profileManager.maxPromptMessages > 0 ? profileManager.maxPromptMessages : settingsManager.maxMessages
                let messagesForContext = Array(self.messages.suffix(maxMessages))
                for message in messagesForContext {
                    if message.role == .user {
                        messages.append(.user(.init(content: .string(message.content))))
                    } else if !message.content.isEmpty {
                        messages.append(.assistant(.init(content: .textContent(message.content))))
                    }
                }
                
                let chatQuery = ChatQuery(
                    messages: messages,
                    model: modelId,
                    stream: true
                )
                
                // Use the OpenAI client's chatsStream method through TinfoilAI
                let stream: AsyncThrowingStream<ChatStreamResult, Error> = client.chatsStream(query: chatQuery)
                
                // Process the stream
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
                let minStreamUpdateInterval: TimeInterval = 0.08
                var lastStreamUpdateTime = Date.distantPast
                var hasPendingUIUpdate = false
                var throttledFlushTask: Task<Void, Never>? = nil

                await MainActor.run {
                    if let chat = self.currentChat,
                       !chat.messages.isEmpty,
                       let lastIndex = chat.messages.indices.last {
                        responseContent = chat.messages[lastIndex].content
                        currentThoughts = chat.messages[lastIndex].thoughts
                        generationTimeSeconds = chat.messages[lastIndex].generationTimeSeconds
                        isInThinkingMode = chat.messages[lastIndex].isThinking
                    }
                }

                func updateCurrentThoughts() {
                    currentThoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                }

                func appendToResponse(_ newContent: String) {
                    if responseContent.isEmpty {
                        responseContent = newContent
                    } else {
                        responseContent += newContent
                    }
                }

                func flushPendingUpdate(throttle: Bool) async {
                    guard hasPendingUIUpdate else { return }
                    let didApply = await MainActor.run { () -> Bool in
                        guard self.currentChat?.id == streamChatId else { return false }
                        guard var chat = self.currentChat,
                              !chat.messages.isEmpty,
                              let lastIndex = chat.messages.indices.last else {
                            return false
                        }
                        chat.messages[lastIndex].content = responseContent
                        chat.messages[lastIndex].thoughts = currentThoughts
                        chat.messages[lastIndex].isThinking = isInThinkingMode
                        chat.messages[lastIndex].generationTimeSeconds = generationTimeSeconds
                        self.updateChat(chat, throttleForStreaming: throttle)
                        return true
                    }
                    if didApply {
                        hasPendingUIUpdate = false
                        lastStreamUpdateTime = Date()
                    }
                }

                defer {
                    throttledFlushTask?.cancel()
                    throttledFlushTask = nil
                }

                for try await chunk in stream {
                    if Task.isCancelled { break }

                    let content = chunk.choices.first?.delta.content ?? ""
                    let hasReasoningContent = chunk.choices.first?.delta.reasoning != nil
                    let reasoningContent = chunk.choices.first?.delta.reasoning ?? ""
                    var forceImmediateUpdate = false
                    var didMutateState = false

                    if hasReasoningContent && !isUsingReasoningFormat && !isInThinkingMode {
                        isUsingReasoningFormat = true
                        isInThinkingMode = true
                        isFirstChunk = false
                        thinkStartTime = Date()
                        thoughtsBuffer = reasoningContent
                        updateCurrentThoughts()
                        didMutateState = true
                        forceImmediateUpdate = true
                    } else if isUsingReasoningFormat {
                        if !reasoningContent.isEmpty {
                            thoughtsBuffer += reasoningContent
                            updateCurrentThoughts()
                            isInThinkingMode = true
                            didMutateState = true
                        }

                        if !content.isEmpty && isInThinkingMode {
                            if let startTime = thinkStartTime {
                                generationTimeSeconds = Date().timeIntervalSince(startTime)
                            }
                            isInThinkingMode = false
                            thinkStartTime = nil
                            updateCurrentThoughts()
                            appendToResponse(content)
                            didMutateState = true
                            forceImmediateUpdate = true
                        } else if !content.isEmpty {
                            appendToResponse(content)
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
                                    updateCurrentThoughts()
                                    didMutateState = true
                                    forceImmediateUpdate = true
                                } else {
                                    appendToResponse(processContent)
                                    didMutateState = true
                                }
                            }
                        } else if hasThinkTag {
                            if let endRange = content.range(of: "</think>") {
                                let beforeEnd = String(content[..<endRange.lowerBound])
                                thoughtsBuffer += beforeEnd
                                updateCurrentThoughts()
                                isInThinkingMode = false

                                let afterEnd = String(content[endRange.upperBound...])
                                appendToResponse(afterEnd)

                                if let startTime = thinkStartTime {
                                    generationTimeSeconds = Date().timeIntervalSince(startTime)
                                }

                                hasThinkTag = false
                                thinkStartTime = nil
                                thoughtsBuffer = ""
                                didMutateState = true
                                forceImmediateUpdate = true
                            } else {
                                thoughtsBuffer += content
                                updateCurrentThoughts()
                                isInThinkingMode = true
                                didMutateState = true
                            }
                        } else {
                            appendToResponse(content)
                            didMutateState = true
                        }
                    }

                    if didMutateState {
                        hasPendingUIUpdate = true
                        let now = Date()
                        let elapsed = now.timeIntervalSince(lastStreamUpdateTime)
                        if forceImmediateUpdate || elapsed >= minStreamUpdateInterval {
                            throttledFlushTask?.cancel()
                            throttledFlushTask = nil
                            await flushPendingUpdate(throttle: true)
                        } else {
                            let remainingDelay = max(minStreamUpdateInterval - elapsed, 0)
                            throttledFlushTask?.cancel()
                            throttledFlushTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: UInt64((remainingDelay * 1_000_000_000).rounded()))
                                if Task.isCancelled { return }
                                await flushPendingUpdate(throttle: true)
                            }
                        }
                    }
                }

                if isInThinkingMode && !thoughtsBuffer.isEmpty {
                    if isUsingReasoningFormat {
                        updateCurrentThoughts()
                    } else {
                        updateCurrentThoughts()
                        if responseContent.isEmpty {
                            responseContent = thoughtsBuffer
                            currentThoughts = nil
                        }
                    }
                    if let startTime = thinkStartTime {
                        generationTimeSeconds = Date().timeIntervalSince(startTime)
                    }
                    isInThinkingMode = false
                    hasPendingUIUpdate = true
                } else if isFirstChunk && !initialContentBuffer.isEmpty {
                    appendToResponse(initialContentBuffer)
                    isInThinkingMode = false
                    currentThoughts = nil
                    hasPendingUIUpdate = true
                }

                throttledFlushTask?.cancel()
                throttledFlushTask = nil

                await flushPendingUpdate(throttle: false)

                // Mark as complete
                await MainActor.run {
                    self.isLoading = false

                    // Mark the chat as no longer having an active stream
                    if var chat = self.currentChat {
                        chat.hasActiveStream = false
                        
                        // Force any pending stream updates to save immediately
                        self.streamUpdateTimer?.invalidate()
                        self.streamUpdateTimer = nil
                        if self.pendingStreamUpdate != nil {
                            self.pendingStreamUpdate = nil
                            if self.hasChatAccess {
                                self.saveChats()
                            }
                        }
                        
                        self.updateChat(chat)  // Final update without throttling

                        // If this was the first exchange and title is still placeholder, generate via LLM
                        if chat.needsGeneratedTitle && chat.messages.count >= 2 {
                            Task { @MainActor in
                                // Snapshot messages for the LLM prompt now
                                let messagesSnapshot = self.currentChat?.messages ?? []
                                guard !messagesSnapshot.isEmpty else { return }

                                if let generated = await self.generateLLMTitle(from: messagesSnapshot) {
                                    // Re-fetch the latest chat after await to avoid using stale IDs
                                    guard var current = self.currentChat, current.messages.count >= 2, current.needsGeneratedTitle else { return }
                                    current.title = generated
                                    current.titleState = .generated
                                    current.locallyModified = true
                                    current.updatedAt = Date()
                                    self.updateChat(current)
                                    // Force an immediate cloud backup to propagate the new title
                                    Task {
                                        try? await self.cloudSync.backupChat(current.id)
                                    }
                                    Chat.triggerSuccessFeedback()
                                }
                            }
                        }
                        
                        // Convert temporary ID to permanent ID after streaming completes
                        if chat.hasTemporaryId && self.authManager?.isAuthenticated == true {
                            Task { @MainActor in
                                do {
                                    let newChat = try await Chat.createWithTimestampId(
                                        modelType: chat.modelType,
                                        language: chat.language,
                                        userId: chat.userId
                                    )
                                    
                                    // Get the current state of the chat
                                    guard let currentChatNow = self.currentChat,
                                          let index = self.chats.firstIndex(where: { $0.id == chat.id }) else {
                                        return
                                    }
                                    
                                    // Update streaming tracker with new ID BEFORE we change the chat
                                    self.streamingTracker.updateChatId(from: chat.id, to: newChat.id)
                                    
                                    // Create updated chat with permanent ID but current state
                                    // IMPORTANT: Keep the original createdAt date from when first message was sent
                                    var updatedChat = Chat(
                                        id: newChat.id,
                                        title: currentChatNow.title,
                                        messages: currentChatNow.messages,
                                        createdAt: currentChatNow.createdAt,  // Keep original date
                                        modelType: currentChatNow.modelType,
                                        language: currentChatNow.language,
                                        userId: currentChatNow.userId,
                                        syncVersion: currentChatNow.syncVersion,
                                        syncedAt: currentChatNow.syncedAt,
                                        locallyModified: true,
                                        updatedAt: Date()
                                    )
                                    updatedChat.hasActiveStream = false
                                    
                                    // Update in the chats array
                                    self.chats[index] = updatedChat
                                    self.currentChat = updatedChat
                                    
                                    // Save the updated chat locally first
                                    self.saveChats()
                                    
                                    // End streaming tracking with NEW ID for cloud sync
                                    self.streamingTracker.endStreaming(updatedChat.id)
                                    
                                    // Now backup to cloud with new permanent ID
                                    try await self.cloudSync.backupChat(updatedChat.id)
                                    
                                    // After successful backup, mark as no longer locally modified
                                    if let index = self.chats.firstIndex(where: { $0.id == updatedChat.id }) {
                                        self.chats[index].locallyModified = false
                                        if self.currentChat?.id == updatedChat.id {
                                            self.currentChat?.locallyModified = false
                                        }
                                    }
                                } catch {
                                    // Still need to end streaming with old ID if conversion fails
                                    self.streamingTracker.endStreaming(chat.id)
                                }
                            }
                        } else if !chat.hasTemporaryId && self.authManager?.isAuthenticated == true {
                            // For chats with permanent IDs, end streaming and backup
                            self.streamingTracker.endStreaming(chat.id)
                            
                            // Save the chat to storage first to ensure we backup the latest version
                            self.saveChats()
                            
                            // Backup now that streaming is complete
                            Task { @MainActor in
                                do {
                                    // Get the latest version of the chat after streaming
                                    guard let latestChat = self.chats.first(where: { $0.id == chat.id }) else {
                                        return
                                    }
                                    
                                    try await self.cloudSync.backupChat(latestChat.id)
                                    
                                    // After successful backup, mark as no longer locally modified
                                    // Note: The chat has already been marked as synced in CloudSyncService.markChatAsSynced
                                    // We just need to update our local state to match
                                    if let index = self.chats.firstIndex(where: { $0.id == latestChat.id }) {
                                        // Reload from storage to get the updated sync state
                                        let updatedChats = Chat.loadFromDefaults(userId: self.currentUserId)
                                        if let syncedChat = updatedChats.first(where: { $0.id == latestChat.id }) {
                                            self.chats[index] = syncedChat
                                            if self.currentChat?.id == latestChat.id {
                                                self.currentChat = syncedChat
                                            }
                                        }
                                    }
                                } catch {
                                }
                            }
                        }
                    }
                }
            } catch {
                // Handle error
                await MainActor.run {
                    self.isLoading = false
                    
                    // Mark the chat as no longer having an active stream
                    if var chat = self.currentChat {
                        chat.hasActiveStream = false
                        
                        // Force any pending stream updates to save immediately
                        self.streamUpdateTimer?.invalidate()
                        self.streamUpdateTimer = nil
                        if self.pendingStreamUpdate != nil {
                            self.pendingStreamUpdate = nil
                            if self.hasChatAccess {
                                self.saveChats()
                            }
                        }
                        
                        self.updateChat(chat)  // Final update without throttling
                        
                        // Convert temporary ID to permanent ID after streaming completes
                        if chat.hasTemporaryId && self.authManager?.isAuthenticated == true {
                            Task { @MainActor in
                                do {
                                    let newChat = try await Chat.createWithTimestampId(
                                        modelType: chat.modelType,
                                        language: chat.language,
                                        userId: chat.userId
                                    )
                                    
                                    // Get the current state of the chat
                                    guard let currentChatNow = self.currentChat,
                                          let index = self.chats.firstIndex(where: { $0.id == chat.id }) else {
                                        return
                                    }
                                    
                                    // Update streaming tracker with new ID BEFORE we change the chat
                                    self.streamingTracker.updateChatId(from: chat.id, to: newChat.id)
                                    
                                    // Create updated chat with permanent ID but current state
                                    // IMPORTANT: Keep the original createdAt date from when first message was sent
                                    var updatedChat = Chat(
                                        id: newChat.id,
                                        title: currentChatNow.title,
                                        messages: currentChatNow.messages,
                                        createdAt: currentChatNow.createdAt,  // Keep original date
                                        modelType: currentChatNow.modelType,
                                        language: currentChatNow.language,
                                        userId: currentChatNow.userId,
                                        syncVersion: currentChatNow.syncVersion,
                                        syncedAt: currentChatNow.syncedAt,
                                        locallyModified: true,
                                        updatedAt: Date()
                                    )
                                    updatedChat.hasActiveStream = false
                                    
                                    // Update in the chats array
                                    self.chats[index] = updatedChat
                                    self.currentChat = updatedChat
                                    
                                    // Save the updated chat locally first
                                    self.saveChats()
                                    
                                    // End streaming tracking with NEW ID for cloud sync
                                    self.streamingTracker.endStreaming(updatedChat.id)
                                    
                                    // Now backup to cloud with new permanent ID
                                    try await self.cloudSync.backupChat(updatedChat.id)
                                    
                                    // After successful backup, mark as no longer locally modified
                                    if let index = self.chats.firstIndex(where: { $0.id == updatedChat.id }) {
                                        self.chats[index].locallyModified = false
                                        if self.currentChat?.id == updatedChat.id {
                                            self.currentChat?.locallyModified = false
                                        }
                                    }
                                } catch {
                                    // Still need to end streaming with old ID if conversion fails
                                    self.streamingTracker.endStreaming(chat.id)
                                }
                            }
                        } else if !chat.hasTemporaryId && self.authManager?.isAuthenticated == true {
                            // For chats with permanent IDs, end streaming and backup
                            self.streamingTracker.endStreaming(chat.id)
                            
                            // Save the chat to storage first to ensure we backup the latest version
                            self.saveChats()
                            
                            // Backup now that streaming is complete
                            Task { @MainActor in
                                do {
                                    // Get the latest version of the chat after streaming
                                    guard let latestChat = self.chats.first(where: { $0.id == chat.id }) else {
                                        return
                                    }
                                    
                                    try await self.cloudSync.backupChat(latestChat.id)
                                    
                                    // After successful backup, mark as no longer locally modified
                                    // Note: The chat has already been marked as synced in CloudSyncService.markChatAsSynced
                                    // We just need to update our local state to match
                                    if let index = self.chats.firstIndex(where: { $0.id == latestChat.id }) {
                                        // Reload from storage to get the updated sync state
                                        let updatedChats = Chat.loadFromDefaults(userId: self.currentUserId)
                                        if let syncedChat = updatedChats.first(where: { $0.id == latestChat.id }) {
                                            self.chats[index] = syncedChat
                                            if self.currentChat?.id == latestChat.id {
                                                self.currentChat = syncedChat
                                            }
                                        }
                                    }
                                } catch {
                                }
                            }
                        }
                    }
                    
                    if var chat = self.currentChat,
                       !chat.messages.isEmpty {
                        let lastIndex = chat.messages.count - 1
                        let lastMessage = chat.messages[lastIndex]
                        
                        // Check if we got partial content before the error
                        let hasPartialContent = !lastMessage.content.isEmpty || lastMessage.thoughts != nil
                        
                        // Format a more user-friendly error message based on the error type
                        let userFriendlyError = formatUserFriendlyError(error)
                        
                        // Handle network connection lost differently if we have partial content
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost && hasPartialContent {
                            // Keep partial content and append a note about the interruption
                            if !chat.messages[lastIndex].content.isEmpty {
                                chat.messages[lastIndex].content += "\n\n[Response interrupted: Network connection lost]"
                            } else {
                                chat.messages[lastIndex].content = "[Response interrupted: Network connection lost]"
                            }
                            chat.messages[lastIndex].streamError = "Network connection lost - response may be incomplete"
                        } else {
                            // For other errors or when no partial content exists, show error message
                            chat.messages[lastIndex].content = "Error: \(userFriendlyError)"
                            chat.messages[lastIndex].streamError = userFriendlyError
                        }
                        
                        // Trigger error haptic feedback
                        Message.triggerErrorFeedback()
                        
                        self.updateChat(chat)
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
    
    /// Cancels the current message generation
    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        
        // Reset the hasActiveStream property
        if var chat = currentChat {
            chat.hasActiveStream = false
            updateChat(chat)
            // End streaming tracking for cloud sync
            streamingTracker.endStreaming(chat.id)
        }
        
        self.showVerifierSheet = false
    }
    
    /// Shows the verifier sheet with current verification state
    func showVerifier() {
        // Use stored measurements from initial verification
        verifierView = VerifierView(
            initialVerificationState: isVerified ? true : (verificationError != nil ? false : nil),
            initialError: verificationError,
            codeDigest: verificationCodeDigest,
            runtimeDigest: verificationRuntimeDigest,
            tlsCertFingerprint: verificationTlsCertFingerprint
        )
        showVerifierSheet = true
    }
    
    /// Dismisses the verifier sheet
    func dismissVerifier() {
        self.showVerifierSheet = false
        self.verifierView = nil
    }
    
    // MARK: - Speech-to-Text Methods
    
    /// Starts speech-to-text recording with microphone permission handling
    func startSpeechToText() {
        Task {
            do {
                // Request microphone permission
                let permissionGranted = await requestMicrophonePermission()
                guard permissionGranted else {
                    return
                }
                
                await MainActor.run {
                    self.isRecording = true
                }
                
                // Setup audio session
                try audioSession.setCategory(.playAndRecord, mode: .default)
                try audioSession.setActive(true)
                
                // Create recording URL
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                recordingURL = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
                
                // Audio recording settings
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                
                // Create and start recorder
                if let url = recordingURL {
                    audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                    audioRecorder?.record()
                }
                
            } catch {
                await MainActor.run {
                    self.isRecording = false
                }
            }
        }
    }
    
    /// Stops speech-to-text recording and processes the audio
    func stopSpeechToText() {
        isRecording = false
        
        // Stop recording
        audioRecorder?.stop()
        
        // Deactivate audio session
        try? audioSession.setActive(false)
        
        // Process the recorded audio
        if let recordingURL = recordingURL {
            processRecordedAudio(sourceURL: recordingURL)
        } else {
        }
    }
    
    /// Requests microphone permission
    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                audioSession.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    
    /// Processes recorded audio file and sends to TinfoilAI for transcription
    private func processRecordedAudio(sourceURL: URL) {
        Task {
            do {
                let audioData = try Data(contentsOf: sourceURL)
                
                // Process the audio data
                processSpeechToTextWithAudio(audioData: audioData)
                
                // Clean up the temporary file
                try FileManager.default.removeItem(at: sourceURL)
                
            } catch {
                await MainActor.run {
                    self.transcribedText = "Audio processing failed. Please try again."
                }
            }
        }
    }
    
    /// Processes recorded audio data for speech-to-text conversion using TinfoilAI
    /// - Parameter audioData: The recorded audio data to be transcribed
    func processSpeechToTextWithAudio(audioData: Data) {
        
        Task {
            do {
                let apiKey = await AppConfig.shared.getApiKey()
                
                guard !apiKey.isEmpty else {
                    throw NSError(domain: "TinfoilChat", code: 401,
                                userInfo: [NSLocalizedDescriptionKey: "Speech-to-text requires authentication. Please sign in to use this feature."])
                }
                
                // Create TinfoilAI client configured for audio processing
                let audioClient = try await TinfoilAI.create(
                    apiKey: apiKey
                )
                
                // Create transcription query
                let transcriptionQuery = AudioTranscriptionQuery(
                    file: audioData,
                    fileType: .m4a,
                    model: "whisper-large-v3-turbo"
                )
                
                // Get transcription from TinfoilAI
                let transcription = try await audioClient.audioTranscriptions(query: transcriptionQuery)
                
                
                await MainActor.run {
                    let transcribedText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !transcribedText.isEmpty {
                        
                        // Auto-send the transcribed message
                        self.sendMessage(text: transcribedText)
                    } else {
                    }
                }
                
            } catch {
                await MainActor.run {
                    
                    // Set user-friendly error message
                    let errorMessage = error.localizedDescription
                    if errorMessage.contains("401") || errorMessage.contains("authentication") {
                        self.transcribedText = "Speech-to-text requires authentication. Please sign in."
                    } else {
                        self.transcribedText = "Speech recognition failed. Please try again."
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Ensures there's always a blank chat at the top of the list
    private func ensureBlankChatAtTop() {
        // Check if the first chat is blank (no messages)
        if let firstChat = chats.first, firstChat.isBlankChat {
            return // Already have a blank chat at top
        }
        
        // Check if any chat in the list is blank
        if let blankChatIndex = chats.firstIndex(where: { $0.isBlankChat }) {
            // Move it to the top
            let blankChat = chats.remove(at: blankChatIndex)
            chats.insert(blankChat, at: 0)
        } else {
            // No blank chat exists, create one
            // It will automatically be blank (no messages) and have a temporary ID (UUID)
            let newBlankChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId
            )
            chats.insert(newBlankChat, at: 0)
            
            // Important: Don't save yet, as this might be called during initialization
            // The calling code will handle saving
        }
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
        
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = updatedChat
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
                        if let _ = self?.pendingStreamUpdate {
                            self?.pendingStreamUpdate = nil
                            if self?.hasChatAccess == true {
                                self?.saveChats()
                            }
                        }
                    }
                }
            } else {
                // Save immediately for non-streaming updates
                if hasChatAccess {
                    saveChats()
                }
            }
        } else {
            // Chat not found in array - this shouldn't happen but handle it
            chats.insert(updatedChat, at: 0)
            
            // Update currentChat if it's the one being updated
            if currentChat?.id == chat.id {
                currentChat = updatedChat
            }
            
            // IMPORTANT: Preserve pagination state when inserting new chats
            // Adding a new chat doesn't affect whether more chats are available to load
            // The hasMoreChats flag should remain unchanged
            
            // Save chats for all authenticated users
            if hasChatAccess {
                saveChats()
            }
        }
    }
    
    /// Saves chats to UserDefaults and triggers cloud backup
    private func saveChats() {
        // Save chats for all authenticated users
        if hasChatAccess {
            // Only save first page of chats + unsaved chats (to prevent persisting paginated data)
            // Keep encrypted chats that failed to decrypt
            let nonEmptyChats = chats.filter { !$0.messages.isEmpty || $0.decryptionFailed }
            
            // Separate into categories
            let oneMinuteAgo = Date().addingTimeInterval(-Constants.Pagination.cleanupThresholdSeconds)
            let syncedChats = nonEmptyChats.filter { chat in
                !chat.isBlankChat && 
                !chat.hasTemporaryId &&
                chat.createdAt < oneMinuteAgo
            }.sorted { $0.createdAt > $1.createdAt }
            
            let unsavedChats = nonEmptyChats.filter { $0.isBlankChat || $0.hasTemporaryId }
            let recentChats = nonEmptyChats.filter { $0.createdAt >= oneMinuteAgo }
            
            // Only save first page of synced chats + all unsaved/recent chats
            let chatsToSave = Array(syncedChats.prefix(Constants.Pagination.chatsPerPage)) + unsavedChats + recentChats
            
            // Remove duplicates
            var seen = Set<String>()
            let uniqueChatsToSave = chatsToSave.filter { chat in
                if seen.contains(chat.id) {
                    return false
                }
                seen.insert(chat.id)
                return true
            }
            
            // Always include the current chat to ensure latest changes (e.g., title) are persisted
            var chatsToPersist = uniqueChatsToSave
            if let current = currentChat, (!current.messages.isEmpty || current.decryptionFailed) {
                if !chatsToPersist.contains(where: { $0.id == current.id }) {
                    chatsToPersist.append(current)
                }
            }

            Chat.saveToDefaults(chatsToPersist, userId: currentUserId)
            
            // Trigger cloud backup for the current chat if it has messages and permanent ID
            // Don't try to backup chats with temporary IDs or while streaming
            if let currentChat = currentChat, 
               !currentChat.messages.isEmpty,
               !currentChat.hasTemporaryId,
               !currentChat.hasActiveStream {
                Task {
                    do {
                        try await cloudSync.backupChat(currentChat.id)
                    } catch {
                    }
                }
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
        let isPremiumModel = AppConfig.shared.getModelConfig(modelType)?.isFree == false
        
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
        
        // Notify of successful model change with haptic feedback
        Chat.triggerSuccessFeedback()
    }
    
    // MARK: - Authentication & Model Access
    
    /// Updates the current model if needed based on auth status changes
    func updateModelBasedOnAuthStatus(isAuthenticated: Bool, hasActiveSubscription: Bool) {
        // Clear any cached API key when auth status changes
        APIKeyManager.shared.clearApiKey()
        
        // Setup Tinfoil client with fresh credentials after auth state changes
        setupTinfoilClient()
        
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
            let savedChats = Chat.loadFromDefaults(userId: currentUserId)
            if !savedChats.isEmpty {
                chats = savedChats
                // Create a new chat instead of selecting from saved chats
                createNewChat()
            }
        }
    }
    
    /// Handle sign-out by clearing current chats but preserving them in storage
    func handleSignOut() {
        // Stop auto-sync timer when signing out
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
        
        // Save current chats before clearing them (they're already associated with the user ID)
        if hasChatAccess {
            saveChats()
        }
        
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
        let newChat = Chat.create(modelType: currentModel)
        currentChat = newChat
        chats = [newChat]
        
    }
    
    /// Clear all local chats and reset to fresh state
    func clearAllLocalChats() {
        // Clear all chats from memory
        chats.removeAll()
        currentChat = nil
        
        // Clear from UserDefaults storage
        if let userId = currentUserId {
            Chat.saveToDefaults([], userId: userId)
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
    
    /// Handle sign-in by loading user's saved chats
    func handleSignIn() {
        print("handleSignIn called")
        
        // Prevent duplicate sign-in flows
        guard !isSignInInProgress else {
            print("handleSignIn: Already in progress, skipping")
            return
        }
        
        print("handleSignIn: hasChatAccess=\(hasChatAccess), userId=\(currentUserId ?? "nil")")
        
        if hasChatAccess, let userId = currentUserId {
            isSignInInProgress = true
            print("handleSignIn: Starting sign-in flow for user \(userId)")
            
            // Restore pagination state immediately for better UX on cold start
            loadPersistedPaginationState()
            
            // If legacy local chats are detected, handle migration path
            if CloudMigrationService.shared.isMigrationNeeded(userId: userId) {
                let decisionMade = CloudMigrationService.shared.hasUserMadeDecision(userId: userId)
                let choseSync = CloudMigrationService.shared.didUserChooseSync(userId: userId) || self.userAgreedToMigrateLegacy

                if decisionMade {
                    if choseSync {
                        // User chose sync previously: run migration automatically if we have a key;
                        // otherwise let ContentView present the key prompt
                        if EncryptionService.shared.hasEncryptionKey() {
                            Task {
                                do {
                                    let _ = try await CloudMigrationService.shared.migrateToCloud(userId: userId)
                                } catch {
                                    // Ignore and continue; errors will surface in sync
                                }
                                await MainActor.run { self.userAgreedToMigrateLegacy = false }
                                await self.startEncryptedSyncFlow()
                            }
                        } else {
                            Task { @MainActor in
                                self.isMigrationDecisionPending = false
                                self.showMigrationPrompt = false
                                self.isSignInInProgress = false
                            }
                        }
                        return
                    } else {
                        // Decision was delete; ensure cleanup and continue
                        CloudMigrationService.shared.deleteLegacyLocalChats(userId: userId)
                        // fallthrough to continue normal flow
                    }
                } else {
                    // No decision yet; present sheet and gate sync immediately (avoid race with auto-sync)
                    self.isMigrationDecisionPending = true
                    self.showMigrationPrompt = true
                    self.isSignInInProgress = false
                    return
                }
            }
            
            // Check if we have any anonymous chats to migrate
            let anonymousChats = chats.filter { chat in
                chat.userId == nil && !chat.messages.isEmpty
            }
            
            if !anonymousChats.isEmpty {
                print("Found \(anonymousChats.count) anonymous chats to migrate")
                // Migrate anonymous chats to the current user
                for var chat in anonymousChats {
                    chat.userId = userId
                    chat.locallyModified = true
                    chat.syncVersion = 0  // Reset sync version to force upload
                    // Update in our chats array
                    if let index = chats.firstIndex(where: { $0.id == chat.id }) {
                        chats[index] = chat
                    }
                }
                // Save the updated chats
                saveChats()
                
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
                    // If no key exists yet, let ContentView present the prompt and stop here
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
                    
                    // If we have anonymous chats to sync, force re-encryption with proper key
                    if self.hasAnonymousChatsToSync {
                        print("Re-encrypting anonymous chats with user's key")
                        // Force all local chats to be marked for sync
                        if let userId = self.currentUserId {
                            var updatedChats = Chat.loadFromDefaults(userId: userId)
                            for i in 0..<updatedChats.count {
                                updatedChats[i].locallyModified = true
                                updatedChats[i].syncVersion = 0
                            }
                            Chat.saveToDefaults(updatedChats, userId: userId)
                        }
                        self.hasAnonymousChatsToSync = false
                    }
                    
                    // Now proceed with cloud sync regardless of whether key was new or existing
                    await initializeCloudSync()
                    
                    // Sync user profile settings
                    await ProfileManager.shared.performFullSync()
                    
                    // Update last sync date
                    await MainActor.run {
                        self.lastSyncDate = Date()
                    }
                    
                    // After sync completes, ensure we have proper chat setup
                    await MainActor.run {
                        if self.chats.isEmpty {
                            self.createNewChat()
                        } else {
                            // Ensure there's a blank chat at the top
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
    
    /// Initialize cloud sync when user signs in
    private func initializeCloudSync() async {
        do {
            // Mark that initial sync has been done to avoid duplicate
            hasPerformedInitialSync = true
            
            // Check if we need to migrate old chats to cloud first
            if let userId = currentUserId, CloudMigrationService.shared.isMigrationNeeded(userId: userId) {
                do {
                    let migrationResult = try await CloudMigrationService.shared.migrateToCloud(userId: userId)
                    
                    if !migrationResult.isSuccess && !migrationResult.errors.isEmpty {
                        // Migration had errors but continue with normal flow
                    }
                } catch {
                    // Continue with normal flow even if migration fails
                }
            }
            
            // Initialize cloud sync service
            try await cloudSync.initialize()
            
            // Perform sync
            let _ = await cloudSync.syncAllChats()
            
            // Load and display synced chats
            if let userId = currentUserId {
                let loadedChats = Chat.loadFromDefaults(userId: userId)
                
                // Debug: Check what we loaded
                for _ in loadedChats.prefix(5) {
                }
                
                let sortedChats = loadedChats.sorted { $0.createdAt > $1.createdAt }
                
                // Include encrypted chats that failed to decrypt (they have decryptionFailed flag)
                // Only filter out truly blank chats (not encrypted ones)
                let displayableChats = sortedChats.filter { chat in
                    // Show if: has messages OR failed to decrypt OR has a non-blank title
                    !chat.messages.isEmpty || chat.decryptionFailed || !chat.needsGeneratedTitle
                }
                
                // Take first page of displayable chats
                let firstPage = Array(displayableChats.prefix(Constants.Pagination.chatsPerPage))
                
                await MainActor.run {
                    if !firstPage.isEmpty {
                        // Replace current chats with synced ones
                        self.chats = firstPage
                        
                        // Only add blank chat if we don't have one already
                        if !self.chats.contains(where: { $0.isBlankChat }) {
                            self.ensureBlankChatAtTop()
                        }
                    } else {
                        // No synced chats, keep the blank chat
                        if self.chats.isEmpty {
                            let newChat = Chat.create(
                                modelType: self.currentModel,
                                language: nil,
                                userId: userId
                            )
                            self.chats = [newChat]
                            self.currentChat = newChat
                        }
                    }
                    
                    // Select the first chat
                    if let first = self.chats.first {
                        self.currentChat = first
                    }
                    
                    // Mark that we've loaded the initial page
                    self.hasLoadedInitialPage = true
                    self.isPaginationActive = displayableChats.count > 0
                    
                    // Set hasMoreChats based on total count
                    self.hasMoreChats = displayableChats.count > Constants.Pagination.chatsPerPage
                }
            }
            
            // Setup pagination token
            await setupPaginationForAppRestart()
        } catch {
            await MainActor.run {
                self.syncErrors.append(error.localizedDescription)
            }
        }
    }

    // MARK: - Legacy Migration Decision Actions
    
    /// User chose to delete legacy local chats instead of migrating
    func confirmDeleteLegacyChats() {
        let userId = currentUserId
        CloudMigrationService.shared.setUserDecision("delete", userId: userId)
        CloudMigrationService.shared.deleteLegacyLocalChats(userId: userId)
        Task { @MainActor in
            self.showMigrationPrompt = false
            self.isMigrationDecisionPending = false
            self.userAgreedToMigrateLegacy = false
            // Always bring up Import Encryption Key view after decision
            self.shouldShowKeyImport = true
        }
        // Continue with normal sign-in flow now that migration is resolved
        Task {
            await self.startEncryptedSyncFlow()
        }
    }
    
    /// User chose to migrate legacy local chats to cloud
    func confirmMigrateLegacyChats() async {
        // Record decision immediately
        CloudMigrationService.shared.setUserDecision("sync", userId: currentUserId)

        // If no encryption key yet, record intent and ask the user to set it up first
        if !EncryptionService.shared.hasEncryptionKey() {
            await MainActor.run {
                self.userAgreedToMigrateLegacy = true
                self.showMigrationPrompt = false
                self.isMigrationDecisionPending = false
                // Always bring up Import Encryption Key view after decision
                self.shouldShowKeyImport = true
            }
            // The UI will prompt for key; after key is set, handleSignIn() will auto-run and migrate
            return
        }

        // Dismiss the sheet immediately for better UX and show syncing state
        await MainActor.run {
            self.showMigrationPrompt = false
            self.isMigrationDecisionPending = false
            self.isSyncing = true
            // Always bring up Import Encryption Key view after decision
            self.shouldShowKeyImport = true
        }

        do {
            // Initialize encryption with existing key and cloud sync
            let key = try await EncryptionService.shared.initialize()
            await MainActor.run { self.encryptionKey = key }
            try await CloudSyncService.shared.initialize()
            // Perform migration
            let result = try await CloudMigrationService.shared.migrateToCloud(userId: currentUserId)
            print("Migration completed: migrated=\(result.migratedCount), failed=\(result.failedCount)")
            if !result.errors.isEmpty { print("Migration errors: \(result.errors)") }
        } catch {
            // Proceed regardless; errors will be surfaced in sync if needed
            print("Migration failed to run: \(error)")
        }

        await MainActor.run {
            self.isSyncing = false
        }

        // Continue with normal sign-in flow
        await startEncryptedSyncFlow()
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

            // Migrate any local chats that still have temporary IDs to server IDs
            let migrationResult = await cloudSync.migrateTemporaryIdChats()
            if !migrationResult.errors.isEmpty {
                await MainActor.run {
                    self.syncErrors.append(contentsOf: migrationResult.errors)
                }
            }
            
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
            if let listResult = try? await R2StorageService.shared.listChats(
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
            
            // Load and display chats after sync
            if let userId = currentUserId {
                let loadedChats = Chat.loadFromDefaults(userId: userId)
                await MainActor.run {
                    self.chats = loadedChats.sorted { $0.createdAt > $1.createdAt }
                    self.ensureBlankChatAtTop()
                }
            }
        } catch {
            print("Failed to perform initial sync: \(error)")
        }
    }
    
    /// Clean up chats beyond first page (called on app launch to ensure clean state)
    private func cleanupPaginatedChats() async {
        guard let userId = currentUserId else { return }
        
        // Load all chats from storage
        let allChats = Chat.loadFromDefaults(userId: userId)
        
        // Filter synced chats (not blank, not temporary, and older than 1 minute to avoid deleting just-created chats)
        let oneMinuteAgo = Date().addingTimeInterval(-Constants.Pagination.cleanupThresholdSeconds)
        let syncedChats = allChats.filter { chat in
            !chat.isBlankChat && 
            !chat.hasTemporaryId &&
            chat.createdAt < oneMinuteAgo  // Only clean up chats older than 1 minute
        }.sorted { $0.createdAt > $1.createdAt }
        
        // Also keep all recent chats (created in last minute) regardless of count
        let recentChats = allChats.filter { chat in
            chat.createdAt >= oneMinuteAgo
        }
        
        // If we have more than first page of old synced chats, keep only the first page
        if syncedChats.count > Constants.Pagination.chatsPerPage {
            
            // Keep first page of synced chats + all unsaved chats (blank/temporary) + recent chats
            let chatsToKeep = Array(syncedChats.prefix(Constants.Pagination.chatsPerPage)) + 
                             allChats.filter { chat in chat.isBlankChat || chat.hasTemporaryId } +
                             recentChats
            
            // Remove duplicates based on chat ID
            var seen = Set<String>()
            let uniqueChats = chatsToKeep.filter { chat in
                if seen.contains(chat.id) {
                    return false
                }
                seen.insert(chat.id)
                return true
            }
            
            Chat.saveToDefaults(uniqueChats, userId: userId)
            
            await MainActor.run {
                self.chats = uniqueChats.sorted { $0.createdAt > $1.createdAt }
            }
        }
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
            // Convert and append new chats
            let newChats = result.chats.map { $0.toChat() }
            
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
        
        // Load all chats from storage (includes newly synced ones)
        let allChats = Chat.loadFromDefaults(userId: userId)
        
        // IMPORTANT: Preserve locally modified chats and chats with active streams
        // Create a map of locally modified chats to preserve them
        let locallyModifiedChats = chats.filter { $0.locallyModified || $0.hasActiveStream || streamingTracker.isStreaming($0.id) }
        let locallyModifiedIds = Set(locallyModifiedChats.map { $0.id })
        
        // Filter out locally modified chats from the synced data to avoid overwriting them
        let syncedChatsFromStorage = allChats.filter { !locallyModifiedIds.contains($0.id) }
        
        // Combine: locally modified chats + synced chats
        let combinedChats = locallyModifiedChats + syncedChatsFromStorage
        
        // Sort by creation date (newest first)
        let sortedChats = combinedChats.sorted { $0.createdAt > $1.createdAt }
        
        // Keep track of currently loaded chat IDs to preserve pagination
        let currentlyLoadedIds = Set(chats.map { $0.id })
        
        // Separate chats into categories
        let twoMinutesAgo = Date().addingTimeInterval(-Constants.Pagination.recentChatThresholdSeconds)
        let recentChats = sortedChats.filter { $0.createdAt >= twoMinutesAgo }
        let unsavedChats = sortedChats.filter { $0.isBlankChat || $0.hasTemporaryId }
        let syncedChats = sortedChats.filter { 
            !$0.isBlankChat && 
            !$0.hasTemporaryId && 
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
                // Keep if it was already loaded OR if it's in the first page positions
                currentlyLoadedIds.contains(chat.id) || syncedChats.firstIndex(where: { $0.id == chat.id }) ?? Int.max < Constants.Pagination.chatsPerPage
            }
            updatedChats.append(contentsOf: syncedChatsToShow)
        } else {
            // Only first page loaded - update just the first page
            updatedChats.append(contentsOf: Array(syncedChats.prefix(Constants.Pagination.chatsPerPage)))
        }
        
        // Remove duplicates based on chat ID
        var seen = Set<String>()
        let uniqueChats = updatedChats.filter { chat in
            if seen.contains(chat.id) {
                return false
            }
            seen.insert(chat.id)
            return true
        }
        
        // Update the chats array
        self.chats = uniqueChats.sorted { $0.createdAt > $1.createdAt }
        
        // Update currentChat if it was synced with new messages
        if let currentChat = self.currentChat,
           !currentChat.locallyModified,
           !currentChat.hasActiveStream,
           let updatedChat = self.chats.first(where: { $0.id == currentChat.id }) {
            // Check if the chat actually changed (different message count or updated timestamp)
            if updatedChat.messages.count != currentChat.messages.count ||
               updatedChat.updatedAt != currentChat.updatedAt {
                self.currentChat = updatedChat
            }
        }
        
        // Ensure blank chat at top
        self.ensureBlankChatAtTop()
        
        // Update hasMoreChats conservatively to preserve server-provided pagination
        let displayedSyncedChats = chats.filter { !$0.isBlankChat && !$0.hasTemporaryId }.count

        // Set to true if we clearly have more locally than are displayed
        if syncedChats.count > displayedSyncedChats {
            self.hasMoreChats = true
        } else if self.paginationToken == nil && syncedChats.count <= Constants.Pagination.chatsPerPage {
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
        // If pagination is active, we need to carefully handle the reload
        if isPaginationActive {
            // Don't reset pagination token during sync
            // Just reload the currently loaded chats
            if let userId = currentUserId {
                let allChats = Chat.loadFromDefaults(userId: userId)
                
                // Sort by creation date (newest first)
                let sortedChats = allChats.sorted { $0.createdAt > $1.createdAt }
                
                // Always keep recently created chats (within last 2 minutes) to avoid losing just-sent messages
                let twoMinutesAgo = Date().addingTimeInterval(-Constants.Pagination.recentChatThresholdSeconds)
                let recentChats = sortedChats.filter { $0.createdAt >= twoMinutesAgo }
                
                // Take the first page worth of chats (10) plus any blank/temporary/recent chats
                let syncedChats = sortedChats.filter { 
                    !$0.isBlankChat && 
                    !$0.hasTemporaryId && 
                    $0.createdAt < twoMinutesAgo 
                }
                let unsavedChats = sortedChats.filter { $0.isBlankChat || $0.hasTemporaryId }
                
                // Keep first page of synced chats + all unsaved chats + all recent chats
                let chatsToShow = Array(syncedChats.prefix(Constants.Pagination.chatsPerPage)) + unsavedChats + recentChats
                
                // Remove duplicates based on chat ID
                var seen = Set<String>()
                let uniqueChats = chatsToShow.filter { chat in
                    if seen.contains(chat.id) {
                        return false
                    }
                    seen.insert(chat.id)
                    return true
                }
                
                // Update the chats array
                self.chats = uniqueChats.sorted { $0.createdAt > $1.createdAt }
                
                // Ensure blank chat at top
                self.ensureBlankChatAtTop()
                
                // Update hasMoreChats based on whether there are more chats beyond the first page
                self.hasMoreChats = syncedChats.count > Constants.Pagination.chatsPerPage
            }
        } else {
            // Not using pagination yet or pagination needs to be reset
            // This happens after initial sync or when pagination hasn't been set up
            if let userId = currentUserId {
                let allChats = Chat.loadFromDefaults(userId: userId)
                
                // Sort by creation date (newest first) 
                let sortedChats = allChats.sorted { $0.createdAt > $1.createdAt }
                
                // Take only first page of chats initially
                self.chats = Array(sortedChats.prefix(Constants.Pagination.chatsPerPage))
                self.ensureBlankChatAtTop()
                
                // Set up pagination based on whether there are more chats
                self.hasMoreChats = sortedChats.count > Constants.Pagination.chatsPerPage
                // Pagination token will be set by initializeCloudSync or setupPaginationForAppRestart
            }
        }
    }
    
    /// Perform a full sync with the cloud
    func performFullSync() async {
        // Gate manual sync until migration choice is made
        if isMigrationDecisionPending {
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
        
        await MainActor.run {
            self.isSyncing = false
            self.lastSyncDate = Date()
            
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
                    if let userId = self.currentUserId {
                        let updatedChats = Chat.loadFromDefaults(userId: userId)
                        await MainActor.run {
                            self.chats = updatedChats
                        }
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
        
        // Reload chats after decryption
        if let userId = currentUserId {
            let updatedChats = Chat.loadFromDefaults(userId: userId)
            await MainActor.run {
                self.chats = updatedChats
            }
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
    /// Generates a concise chat title using a free LLM, based on the first few messages.
    fileprivate func generateLLMTitle(from messages: [Message]) async -> String? {
        // Require at least one message
        guard !messages.isEmpty else { return nil }

        // Pick a free model, prefer a llama-free-like id
        let freeModels = AppConfig.shared.availableModels.filter { $0.isFree }
        guard !freeModels.isEmpty else { return nil }
        let preferred = freeModels.first { $0.modelName.lowercased().contains("llama") && $0.modelName.lowercased().contains("free") }
        let modelToUse = preferred ?? freeModels[0]

        // Prepare conversation snippet (first few messages)
        let snippet = messages.prefix(4).map { msg -> String in
            let role = (msg.role == .user) ? "USER" : "ASSISTANT"
            return "\(role): \(msg.content.prefix(500))"
        }.joined(separator: "\n\n")

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

        let titlePrompt = "You are a conversation title generator. Your job is to generate a title for the following conversation between the USER and the ASSISTANT. Generate a concise, descriptive title (max 15 tokens) for this conversation. Output ONLY the title, nothing else."

        // Build messages
        let params: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(titlePrompt))),
            .user(.init(content: .string("Generate a title for this conversation:\n\n\(snippet)")))
        ]

        let query = ChatQuery(
            messages: params,
            model: modelToUse.modelName,
            stream: true
        )

        // Collect streamed content
        var buffer = ""
        do {
            let stream: AsyncThrowingStream<ChatStreamResult, Error> = client.chatsStream(query: query)
            for try await chunk in stream {
                if let piece = chunk.choices.first?.delta.content, !piece.isEmpty {
                    buffer += piece
                }
            }
        } catch {
            return nil
        }

        let raw = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Clean quotes and clamp length
        let clean = raw
            .replacingOccurrences(of: "^\"|\"$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^'|'$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty, clean.count <= 80 else { return nil }
        return clean
    }
}
