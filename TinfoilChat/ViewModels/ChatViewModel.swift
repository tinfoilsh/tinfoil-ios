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
    @Published var lastSyncDate: Date?
    @Published var syncErrors: [String] = []
    @Published var encryptionKey: String?
    @Published var isFirstTimeUser: Bool = false
    @Published var showEncryptionSetup: Bool = false
    @Published var showSyncErrorRecovery: Bool = false
    private let cloudSync = CloudSyncService.shared
    private let streamingTracker = StreamingTracker.shared
    
    // Pagination properties
    @Published var isLoadingMore: Bool = false
    @Published var hasMoreChats: Bool = false
    private var paginationToken: String? = nil
    private var isPaginationActive: Bool = false  // Track if we're using pagination vs full load
    private var hasLoadedInitialPage: Bool = false  // Track if we've loaded the first page
    private var hasAttemptedLoadMore: Bool = false  // Track if we've tried to load more at least once
    
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
    
    // Auth reference for Premium features
    @Published var authManager: AuthManager?
    
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
        
        // Store auth manager reference
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
            paginationToken = nil
            hasMoreChats = false
            isPaginationActive = false
            hasLoadedInitialPage = false
            hasAttemptedLoadMore = false
        } else {
            // For non-authenticated users, just create a single chat without saving
            let newChat = Chat.create(modelType: currentModel)
            currentChat = newChat
            chats = [newChat]
            
        }
        
        // Setup app lifecycle observers
        setupAppLifecycleObservers()
        
        // Set up auto-sync timer if already authenticated (e.g., app launch with existing session)
        if authManager?.isAuthenticated == true {
            setupAutoSyncTimer()
            
            // Initialize cloud sync and perform immediate sync on app restart
            Task {
                // Initialize cloud sync service first
                do {
                    // Initialize encryption
                    let key = try await EncryptionService.shared.initialize()
                    await MainActor.run {
                        self.encryptionKey = key
                    }
                    
                    // Initialize cloud sync
                    try await cloudSync.initialize()
                    
                    // Perform immediate sync on app launch/restart
                    print("🔄 Performing initial sync on app launch...")
                    let syncResult = await cloudSync.syncAllChats()
                    print("✅ Initial sync completed (uploaded: \(syncResult.uploaded), downloaded: \(syncResult.downloaded))")
                    
                    // Setup pagination after sync
                    await setupPaginationForAppRestart()
                    
                    // Load and display chats after sync
                    if let userId = currentUserId {
                        let loadedChats = Chat.loadFromDefaults(userId: userId)
                        print("📱 Loaded \(loadedChats.count) chats from storage after sync")
                        
                        // Sort by creation date (newest first)
                        let sortedChats = loadedChats.sorted { $0.createdAt > $1.createdAt }
                        
                        // For initial sync, don't filter by time - just separate synced vs unsaved
                        let syncedChats = sortedChats.filter { chat in
                            !chat.isBlankChat && 
                            !chat.hasTemporaryId
                        }
                        let unsavedChats = sortedChats.filter { $0.isBlankChat || $0.hasTemporaryId }
                        
                        print("📊 Synced chats: \(syncedChats.count), Unsaved chats: \(unsavedChats.count)")
                        
                        // Keep only first page of synced chats + all unsaved chats
                        var chatsToKeep = Array(syncedChats.prefix(Constants.Pagination.chatsPerPage)) + unsavedChats
                        
                        // Remove duplicates
                        var seen = Set<String>()
                        chatsToKeep = chatsToKeep.filter { chat in
                            if seen.contains(chat.id) {
                                return false
                            }
                            seen.insert(chat.id)
                            return true
                        }
                        
                        // Save cleaned up chats back to storage
                        if !chatsToKeep.isEmpty {
                            Chat.saveToDefaults(chatsToKeep, userId: currentUserId)
                        }
                        
                        // Display the first page
                        let firstPageChats = Array(chatsToKeep.sorted { $0.createdAt > $1.createdAt }.prefix(Constants.Pagination.chatsPerPage))
                        
                        print("📄 Displaying \(firstPageChats.count) chats in UI")
                        
                        await MainActor.run {
                            // Update chats array with synced data
                            if !firstPageChats.isEmpty {
                                self.chats = firstPageChats
                                self.ensureBlankChatAtTop()
                                print("✅ Updated UI with \(self.chats.count) chats")
                                
                                // Select the first chat
                                if let first = self.chats.first {
                                    self.currentChat = first
                                    print("📍 Selected chat: \(first.id) - isBlank: \(first.isBlankChat)")
                                }
                            } else {
                                // No chats loaded, ensure we have at least a blank chat
                                if self.chats.isEmpty || !self.chats[0].isBlankChat {
                                    let newChat = Chat.create(
                                        modelType: self.currentModel,
                                        language: nil,
                                        userId: userId
                                    )
                                    self.chats = [newChat]
                                    self.currentChat = newChat
                                }
                            }
                            
                            // Update pagination state
                            self.hasMoreChats = syncedChats.count > Constants.Pagination.chatsPerPage
                            self.hasLoadedInitialPage = true
                            self.isPaginationActive = syncedChats.count > 0
                        }
                    }
                } catch {
                    print("❌ Failed to initialize cloud sync on app launch: \(error)")
                }
            }
        }
    }
    
    deinit {
        // Stop auto-sync timer
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
        
        // Remove app lifecycle observers
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Setup auto-sync timer to sync every 30 seconds
    private func setupAutoSyncTimer() {
        // Invalidate existing timer if any
        autoSyncTimer?.invalidate()
        
        print("📅 Setting up auto-sync timer (every \(Int(Constants.Sync.autoSyncIntervalSeconds)) seconds)")
        
        // Create timer that fires at regular intervals
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: Constants.Sync.autoSyncIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Only sync if authenticated
            guard self.authManager?.isAuthenticated == true else {
                print("⏭️ Auto-sync skipped - not authenticated")
                return
            }
            
            print("🔄 Auto-sync starting...")
            
            // Perform sync in background
            Task {
                do {
                    // Sync all chats
                    let syncResult = try await self.cloudSync.syncAllChats()
                    print("✅ Auto-sync completed successfully (uploaded: \(syncResult.uploaded), downloaded: \(syncResult.downloaded))")
                    
                    // If we downloaded new chats, reload the chat list
                    if syncResult.downloaded > 0 {
                        // Use intelligent update that preserves pagination
                        await self.updateChatsAfterSync()
                        
                        // Force UI update
                        await MainActor.run {
                            self.objectWillChange.send()
                            
                            // Restore current chat selection if it still exists
                            if let currentChatId = self.currentChat?.id,
                               let chat = self.chats.first(where: { $0.id == currentChatId }) {
                                self.currentChat = chat
                            }
                        }
                        
                        print("📱 Updated chats after sync (downloaded: \(syncResult.downloaded))")
                    }
                    
                    // Also backup current chat if it has changes
                    if let currentChat = await MainActor.run(body: { self.currentChat }),
                       !currentChat.hasTemporaryId,
                       !currentChat.messages.isEmpty,
                       !currentChat.hasActiveStream {
                        try await self.cloudSync.backupChat(currentChat.id)
                        print("✅ Current chat backed up: \(currentChat.id)")
                    }
                } catch {
                    print("❌ Auto-sync failed: \(error)")
                }
            }
        }
    }
    
    /// Setup observers for app lifecycle events
    private func setupAppLifecycleObservers() {
        // Listen for app becoming active (returning from background)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Add a small delay to allow auth state to stabilize, then retry client setup if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.retryClientSetup()
            }
            
            // Resume auto-sync timer if authenticated
            if self?.authManager?.isAuthenticated == true {
                self?.setupAutoSyncTimer()
                
                // Perform immediate sync when returning from background
                Task {
                    print("🔄 Performing sync after returning from background...")
                    if let syncResult = try? await self?.cloudSync.syncAllChats() {
                        print("✅ Background return sync completed (uploaded: \(syncResult.uploaded), downloaded: \(syncResult.downloaded))")
                        
                        // Update chats if needed
                        if syncResult.downloaded > 0 {
                            await self?.updateChatsAfterSync()
                        }
                    }
                }
            }
        }
        
        // Listen for app going to background
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Pause auto-sync timer
            self?.autoSyncTimer?.invalidate()
            self?.autoSyncTimer = nil
            
            // Do one final sync before going to background
            if self?.authManager?.isAuthenticated == true {
                Task {
                    try? await self?.cloudSync.syncAllChats()
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
            shouldFocusInput = true
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
        shouldFocusInput = true
    }
    
    /// Selects a chat as the current chat
    func selectChat(_ chat: Chat) {
        print("🔄 selectChat called with: \(chat.id), isBlank: \(chat.isBlankChat)")
        
        // Cancel any ongoing generation first
        if isLoading {
            cancelGeneration()
        }
        
        // Find the most up-to-date version of the chat in the chats array
        let chatToSelect: Chat
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chatToSelect = chats[index]
            print("✅ Found chat in array at index \(index)")
        } else {
            chatToSelect = chat
            if !chats.contains(where: { $0.id == chat.id }) {
                chats.append(chatToSelect) // Add if truly new
                print("📝 Added chat to array")
            }
        }
        
        currentChat = chatToSelect
        print("✅ Current chat set to: \(currentChat?.id ?? "nil")")
        
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
            chats[index].title = newTitle
            if currentChat?.id == id {
                currentChat?.title = newTitle
            }
            saveChats()
        }
    }
    
    /// Sends a user message and generates a response
    func sendMessage(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        print("📨 sendMessage called - currentChat: \(currentChat?.id ?? "nil"), isBlank: \(currentChat?.isBlankChat ?? false)")
        
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        // Update UI state  
        isLoading = true
        
        // Create and add user message
        let userMessage = Message(role: .user, content: text)
        addMessage(userMessage)
        
        // If this is the first message, update creation date and generate title
        if var chat = currentChat, chat.messages.count == 1 {
            // Update creation date to now (when first message is sent)
            chat.createdAt = Date()
            chat.updatedAt = Date()
            
            // Generate title
            let generatedTitle = Chat.generateTitle(from: text)
            chat.title = generatedTitle
            
            updateChat(chat)
            // Trigger success haptic feedback for title generation
            Chat.triggerSuccessFeedback()
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
        let streamingChat = currentChat
        let streamMessageCount = currentChat?.messages.count ?? 0
        
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
                var systemPrompt: String
                
                // Use custom prompt if enabled, otherwise use default
                if settingsManager.isUsingCustomPrompt && !settingsManager.customSystemPrompt.isEmpty {
                    systemPrompt = settingsManager.customSystemPrompt
                } else {
                    systemPrompt = AppConfig.shared.systemPrompt
                }
                
                // Replace MODEL_NAME placeholder with current model name
                systemPrompt = systemPrompt.replacingOccurrences(of: "{MODEL_NAME}", with: currentModel.fullName)
                
                // Replace language placeholder
                if let chat = currentChat, let language = chat.language {
                    systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: language)
                } else {
                    systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: "English")
                }
                
                // Add personalization XML if enabled
                let personalizationXML = settingsManager.generateUserPreferencesXML()
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
                
                // Build messages array inline
                var messages: [ChatQuery.ChatCompletionMessageParam] = [
                    .system(.init(content: .textContent(systemPrompt)))
                ]
                
                // Add conversation messages
                let messagesForContext = Array(self.messages.suffix(settingsManager.maxMessages))
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
                
                for try await chunk in stream {
                    // Get the content from the delta
                    let content = chunk.choices.first?.delta.content ?? ""
                    
                    // Check for reasoning content (supports both reasoning and reasoning_content fields)
                    let hasReasoningContent = chunk.choices.first?.delta.reasoning != nil
                    let reasoningContent = chunk.choices.first?.delta.reasoning ?? ""
                    
                    // Update UI on main thread
                    await MainActor.run {
                        // Get current chat and validate it has messages
                        guard var chat = self.currentChat,
                              !chat.messages.isEmpty,
                              let lastIndex = chat.messages.indices.last else { 
                            print("⚠️ Stream update skipped: no current chat or no messages")
                            return 
                        }
                        
                        // Detect start of reasoning_content format
                        if hasReasoningContent && !isUsingReasoningFormat && !isInThinkingMode {
                            isUsingReasoningFormat = true
                            isInThinkingMode = true
                            isFirstChunk = false
                            thinkStartTime = Date() // Track when thinking started
                            
                            if !reasoningContent.isEmpty {
                                thoughtsBuffer = reasoningContent
                                chat.messages[lastIndex].thoughts = thoughtsBuffer
                                chat.messages[lastIndex].isThinking = true
                                self.updateChat(chat)
                            }
                        } else if isUsingReasoningFormat {
                            // Continue with reasoning format
                            if !reasoningContent.isEmpty {
                                thoughtsBuffer += reasoningContent
                                // Update thoughts in real-time for streaming
                                chat.messages[lastIndex].thoughts = thoughtsBuffer
                                chat.messages[lastIndex].isThinking = true
                            }
                            
                            // Check if regular content has appeared - this signals end of thinking
                            if !content.isEmpty && isInThinkingMode {
                                // Calculate generation time before clearing thinkStartTime
                                if let startTime = thinkStartTime {
                                    chat.messages[lastIndex].generationTimeSeconds = Date().timeIntervalSince(startTime)
                                }
                                
                                isInThinkingMode = false
                                thinkStartTime = nil
                                
                                // Finalize thoughts and start regular content
                                chat.messages[lastIndex].thoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                chat.messages[lastIndex].isThinking = false
                                chat.messages[lastIndex].content = content
                            } else if !content.isEmpty {
                                // Regular content after thinking has ended
                                chat.messages[lastIndex].content += content
                                chat.messages[lastIndex].isThinking = false
                            }
                            
                            // Always update if we got any new content
                            if !reasoningContent.isEmpty || !content.isEmpty {
                                self.updateChat(chat)
                            }
                        } else if !isUsingReasoningFormat && !content.isEmpty {
                            // Handle original <think> tag format
                            if isFirstChunk {
                                initialContentBuffer += content
                                
                                // Check if we have enough content to determine format
                                if initialContentBuffer.contains("<think>") || initialContentBuffer.count > 5 {
                                    isFirstChunk = false
                                    let processContent = initialContentBuffer
                                    initialContentBuffer = ""
                                    
                                    // Check for think tag
                                    if processContent.contains("<think>") {
                                        isInThinkingMode = true
                                        hasThinkTag = true
                                        thinkStartTime = Date()
                                        
                                        // Extract thoughts from <think> tags
                                        if let thinkRange = processContent.range(of: "<think>") {
                                            let afterThink = String(processContent[thinkRange.upperBound...])
                                            thoughtsBuffer = afterThink
                                            chat.messages[lastIndex].thoughts = thoughtsBuffer
                                            chat.messages[lastIndex].isThinking = true
                                        }
                                    } else {
                                        // Regular content
                                        chat.messages[lastIndex].content += processContent
                                    }
                                    self.updateChat(chat)
                                }
                            } else if hasThinkTag {
                                // Continue processing think tag content
                                if content.contains("</think>") {
                                    // End of thinking
                                    if let endRange = content.range(of: "</think>") {
                                        let beforeEnd = String(content[..<endRange.lowerBound])
                                        thoughtsBuffer += beforeEnd
                                        
                                        chat.messages[lastIndex].thoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                        chat.messages[lastIndex].isThinking = false
                                        
                                        // Add content after </think>
                                        let afterEnd = String(content[endRange.upperBound...])
                                        chat.messages[lastIndex].content = afterEnd
                                        
                                        // Calculate generation time
                                        if let startTime = thinkStartTime {
                                            chat.messages[lastIndex].generationTimeSeconds = Date().timeIntervalSince(startTime)
                                        }
                                        
                                        hasThinkTag = false
                                        isInThinkingMode = false
                                        thinkStartTime = nil
                                        thoughtsBuffer = ""
                                    }
                                } else {
                                    // Continue accumulating thoughts
                                    thoughtsBuffer += content
                                    chat.messages[lastIndex].thoughts = thoughtsBuffer
                                }
                                self.updateChat(chat)
                            } else {
                                // Regular content (no thinking)
                                chat.messages[lastIndex].content += content
                                self.updateChat(chat)
                            }
                        }
                    }
                }
                
                // Mark as complete
                await MainActor.run {
                    self.isLoading = false
                    
                    // Handle any remaining buffered content when stream ends
                    if var chat = self.currentChat,
                       !chat.messages.isEmpty,
                       let lastIndex = chat.messages.indices.last {
                        
                        // If we're still in thinking mode when stream ends
                        if isInThinkingMode && !thoughtsBuffer.isEmpty {
                            isInThinkingMode = false
                            
                            if isUsingReasoningFormat {
                                // For reasoning_content format, keep thoughts as thoughts
                                chat.messages[lastIndex].thoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                chat.messages[lastIndex].isThinking = false
                            } else {
                                // For <think> format without closing tag, convert thoughts to content
                                chat.messages[lastIndex].thoughts = thoughtsBuffer.isEmpty ? nil : thoughtsBuffer
                                chat.messages[lastIndex].isThinking = false
                                // If there's no content yet, move thoughts to content
                                if chat.messages[lastIndex].content.isEmpty {
                                    chat.messages[lastIndex].content = thoughtsBuffer
                                    chat.messages[lastIndex].thoughts = nil
                                }
                            }
                            
                            // Calculate generation time
                            if let startTime = thinkStartTime {
                                chat.messages[lastIndex].generationTimeSeconds = Date().timeIntervalSince(startTime)
                            }
                            
                            self.updateChat(chat)
                        } else if isFirstChunk && !initialContentBuffer.isEmpty {
                            // Process any buffered content that wasn't processed
                            chat.messages[lastIndex].content = initialContentBuffer
                            self.updateChat(chat)
                        }
                    }
                    
                    // Mark the chat as no longer having an active stream
                    if var chat = self.currentChat {
                        chat.hasActiveStream = false
                        self.updateChat(chat)
                        
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
                                        print("⚠️ Cannot convert ID: currentChat is nil or chat not in array")
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
                                    print("Backing up chat after ID conversion from \(chat.id) to \(updatedChat.id)")
                                    try await self.cloudSync.backupChat(updatedChat.id)
                                    print("Successfully backed up converted chat: \(updatedChat.id)")
                                } catch {
                                    print("Failed to generate permanent ID or backup: \(error)")
                                    // Still need to end streaming with old ID if conversion fails
                                    self.streamingTracker.endStreaming(chat.id)
                                }
                            }
                        } else if !chat.hasTemporaryId && self.authManager?.isAuthenticated == true {
                            // For chats with permanent IDs, end streaming and backup
                            self.streamingTracker.endStreaming(chat.id)
                            
                            // Backup now that streaming is complete
                            Task { @MainActor in
                                do {
                                    // Get the latest version of the chat after streaming
                                    guard let latestChat = self.chats.first(where: { $0.id == chat.id }) else {
                                        return
                                    }
                                    
                                    print("Backing up chat with permanent ID: \(latestChat.id)")
                                    try await self.cloudSync.backupChat(latestChat.id)
                                    print("Successfully backed up chat: \(latestChat.id)")
                                } catch {
                                    print("Failed to backup chat \(chat.id): \(error)")
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
                        self.updateChat(chat)
                        
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
                                        print("⚠️ Cannot convert ID: currentChat is nil or chat not in array")
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
                                    print("Backing up chat after ID conversion from \(chat.id) to \(updatedChat.id)")
                                    try await self.cloudSync.backupChat(updatedChat.id)
                                    print("Successfully backed up converted chat: \(updatedChat.id)")
                                } catch {
                                    print("Failed to generate permanent ID or backup: \(error)")
                                    // Still need to end streaming with old ID if conversion fails
                                    self.streamingTracker.endStreaming(chat.id)
                                }
                            }
                        } else if !chat.hasTemporaryId && self.authManager?.isAuthenticated == true {
                            // For chats with permanent IDs, end streaming and backup
                            self.streamingTracker.endStreaming(chat.id)
                            
                            // Backup now that streaming is complete
                            Task { @MainActor in
                                do {
                                    // Get the latest version of the chat after streaming
                                    guard let latestChat = self.chats.first(where: { $0.id == chat.id }) else {
                                        return
                                    }
                                    
                                    print("Backing up chat with permanent ID: \(latestChat.id)")
                                    try await self.cloudSync.backupChat(latestChat.id)
                                    print("Successfully backed up chat: \(latestChat.id)")
                                } catch {
                                    print("Failed to backup chat \(chat.id): \(error)")
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
        return await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { granted in
                continuation.resume(returning: granted)
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
            print("✅ Already have blank chat at top: \(firstChat.id)")
            return // Already have a blank chat at top
        }
        
        // Check if any chat in the list is blank
        if let blankChatIndex = chats.firstIndex(where: { $0.isBlankChat }) {
            // Move it to the top
            let blankChat = chats.remove(at: blankChatIndex)
            chats.insert(blankChat, at: 0)
            print("📝 Moved existing blank chat to top: \(blankChat.id)")
        } else {
            // No blank chat exists, create one
            // It will automatically be blank (no messages) and have a temporary ID (UUID)
            let newBlankChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId
            )
            chats.insert(newBlankChat, at: 0)
            print("📝 Created new blank chat: \(newBlankChat.id)")
            
            // Important: Don't save yet, as this might be called during initialization
            // The calling code will handle saving
        }
    }
    
    /// Adds a message to the current chat
    private func addMessage(_ message: Message) {
        guard var chat = currentChat else { 
            print("❌ addMessage: No current chat!")
            return 
        }
        
        print("✅ addMessage: Adding message to chat \(chat.id)")
        
        // Add directly to the full message list
        chat.messages.append(message)
        
        updateChat(chat) // Saves the full list
    }
    
    /// Updates a chat in the chats array AND saves
    private func updateChat(_ chat: Chat) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
            // Update currentChat directly ONLY IF it's the one being updated
            if currentChat?.id == chat.id {
                currentChat = chat
            }
            
            // Save chats for all authenticated users
            if hasChatAccess {
                saveChats()
            }
        } else {
            // Chat not found in array - this shouldn't happen but handle it
            print("⚠️ updateChat: Chat \(chat.id) not found in array! Adding it.")
            chats.insert(chat, at: 0)
            
            // Update currentChat if it's the one being updated
            if currentChat?.id == chat.id {
                currentChat = chat
            }
            
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
            
            Chat.saveToDefaults(uniqueChatsToSave, userId: currentUserId)
            
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
                        print("Failed to backup chat during save: \(error)")
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
        print("⏹️ Auto-sync timer stopped (signed out)")
        
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
        if hasChatAccess, let userId = currentUserId {
            // Start auto-sync timer now that user is authenticated
            // (This also handles the case where someone signs in after app launch)
            setupAutoSyncTimer()
            
            // Check if we need to set up encryption first
            let existingKey = EncryptionService.shared.getKey()
            if existingKey == nil {
                // Auto-generate encryption key for new users (matches React behavior)
                Task {
                    do {
                        let newKey = try await EncryptionService.shared.initialize()
                        self.encryptionKey = newKey
                        
                        // Now proceed with cloud sync
                        await initializeCloudSync()
                        
                        // After sync completes, ensure we have proper chat setup
                        await MainActor.run {
                            if self.chats.isEmpty {
                                self.createNewChat()
                            } else {
                                // Ensure there's a blank chat at the top
                                self.ensureBlankChatAtTop()
                            }
                        }
                    } catch {
                        // If key generation fails, fall back to showing setup modal
                        await MainActor.run {
                            self.isFirstTimeUser = true
                            self.showEncryptionSetup = true
                        }
                    }
                }
                return
            }
            
            // We have an encryption key, perform immediate sync
            Task {
                print("🔄 handleSignIn: Performing immediate sync...")
                
                // Initialize encryption and cloud sync
                do {
                    let key = try await EncryptionService.shared.initialize()
                    self.encryptionKey = key
                    try await cloudSync.initialize()
                    
                    // Perform sync
                    let syncResult = await cloudSync.syncAllChats()
                    print("✅ handleSignIn: Sync completed (uploaded: \(syncResult.uploaded), downloaded: \(syncResult.downloaded))")
                    
                    // Load and display synced chats
                    if let userId = currentUserId {
                        let loadedChats = Chat.loadFromDefaults(userId: userId)
                        print("📚 handleSignIn: Total loaded chats: \(loadedChats.count)")
                        
                        // Debug: Check what we loaded
                        for chat in loadedChats.prefix(5) {
                            print("  - Chat: \(chat.id), blank: \(chat.isBlankChat), messages: \(chat.messages.count), title: \(chat.title), decryptionFailed: \(chat.decryptionFailed)")
                        }
                        
                        let sortedChats = loadedChats.sorted { $0.createdAt > $1.createdAt }
                        
                        // Include encrypted chats that failed to decrypt (they have decryptionFailed flag)
                        // Only filter out truly blank chats (not encrypted ones)
                        let displayableChats = sortedChats.filter { chat in
                            // Show if: has messages OR failed to decrypt OR has a non-blank title
                            !chat.messages.isEmpty || chat.decryptionFailed || !chat.title.contains("New Chat")
                        }
                        print("📊 handleSignIn: Displayable chats (including encrypted): \(displayableChats.count)")
                        
                        // Take first page of displayable chats
                        let firstPage = Array(displayableChats.prefix(Constants.Pagination.chatsPerPage))
                        
                        print("📄 handleSignIn: Displaying \(firstPage.count) chats (including blanks)")
                        
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
                                self.ensureBlankChatAtTop()
                            }
                            
                            print("🎯 Final chat count in UI: \(self.chats.count)")
                            
                            if let first = self.chats.first {
                                self.currentChat = first
                            }
                            
                            // Force UI update
                            self.objectWillChange.send()
                            
                            // Set pagination state
                            self.hasMoreChats = sortedChats.count > Constants.Pagination.chatsPerPage
                            self.hasLoadedInitialPage = true
                            self.isPaginationActive = true
                        }
                    }
                    
                    // Setup pagination token
                    await setupPaginationForAppRestart()
                } catch {
                    print("❌ handleSignIn: Failed to sync: \(error)")
                }
            }
        } else {
        }
    }
    
    // MARK: - Cloud Sync Methods
    
    /// Initialize cloud sync when user signs in
    private func initializeCloudSync() async {
        do {
            // Check if we have an existing key
            let existingKey = EncryptionService.shared.getKey()
            
            if existingKey == nil {
                // First-time user - show setup modal
                await MainActor.run {
                    self.isFirstTimeUser = true
                    self.showEncryptionSetup = true
                }
                // Don't proceed until user sets up encryption
                return
            }
            
            // Initialize encryption with existing key
            let key = try await EncryptionService.shared.initialize()
            await MainActor.run {
                self.encryptionKey = key
                self.isFirstTimeUser = false
            }
            
            // Initialize cloud sync service
            try await cloudSync.initialize()
            
            // Clean up chats beyond first page ONLY on app launch (not during runtime)
            // Check if this is initial app launch vs runtime sign-in
            if chats.isEmpty {
                await cleanupPaginatedChats()
            }
            
            // Perform initial sync which loads ONLY the first page of chats
            await performFullSync()
            
            // Load chats from storage after sync
            if let userId = currentUserId {
                let loadedChats = Chat.loadFromDefaults(userId: userId)
                print("📱 initializeCloudSync: Loaded \(loadedChats.count) chats from storage")
                
                // Sort and take only first page for display
                let sortedChats = loadedChats.sorted { $0.createdAt > $1.createdAt }
                let nonBlankChats = sortedChats.filter { !$0.isBlankChat }
                print("📊 initializeCloudSync: \(nonBlankChats.count) non-blank chats available")
                
                let firstPageChats = Array(nonBlankChats.prefix(Constants.Pagination.chatsPerPage))
                print("📄 initializeCloudSync: Displaying \(firstPageChats.count) chats in first page")
                
                await MainActor.run {
                    // Update chats with synced data
                    if !firstPageChats.isEmpty {
                        self.chats = firstPageChats
                        self.ensureBlankChatAtTop()
                        print("✅ initializeCloudSync: Updated UI with \(self.chats.count) chats")
                    } else {
                        print("⚠️ initializeCloudSync: No synced chats to display, keeping blank chat")
                        // No synced chats, ensure we have at least the blank chat
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
                        print("🔵 Selected chat after sync: \(first.id) - isBlank: \(first.isBlankChat)")
                    }
                    
                    // Mark that we've loaded the initial page
                    self.hasLoadedInitialPage = true
                    self.isPaginationActive = nonBlankChats.count > 0
                    
                    // Set hasMoreChats based on total count
                    self.hasMoreChats = nonBlankChats.count > Constants.Pagination.chatsPerPage
                }
            }
            
            // Get pagination token for page 2
            // This needs to happen AFTER we've loaded the first page
            if let listResult = try? await R2StorageService.shared.listChats(
                limit: Constants.Pagination.chatsPerPage,
                continuationToken: nil,
                includeContent: false
            ) {
                await MainActor.run {
                    self.paginationToken = listResult.nextContinuationToken
                    self.hasMoreChats = listResult.hasMore
                    print("📄 Pagination initialized - hasMore: \(listResult.hasMore), token: \(listResult.nextContinuationToken?.prefix(20) ?? "nil")")
                }
            }
        } catch {
            await MainActor.run {
                self.syncErrors.append(error.localizedDescription)
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
                    print("📄 Pagination setup for app restart - hasMore: \(listResult.hasMore), token: \(listResult.nextContinuationToken?.prefix(20) ?? "nil")")
                }
            }
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
            print("📄 Cleaning up paginated chats: keeping first \(Constants.Pagination.chatsPerPage), removing \(syncedChats.count - Constants.Pagination.chatsPerPage)")
            
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
            // No token means no more pages
            await MainActor.run {
                self.hasMoreChats = false
            }
            return
        }
        
        await MainActor.run {
            self.isLoadingMore = true
            self.hasAttemptedLoadMore = true  // Track that user has loaded additional pages
        }
        
        // Load next page with the token
        let result = await cloudSync.loadChatsWithPagination(
            limit: 10,
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
        
        // Load all chats from storage (includes newly synced ones)
        let allChats = Chat.loadFromDefaults(userId: userId)
        
        // Sort by creation date (newest first)
        let sortedChats = allChats.sorted { $0.createdAt > $1.createdAt }
        
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
        
        // Ensure blank chat at top
        self.ensureBlankChatAtTop()
        
        // Update hasMoreChats if needed (but don't reset pagination token)
        if syncedChats.count > chats.filter { !$0.isBlankChat && !$0.hasTemporaryId }.count {
            self.hasMoreChats = true
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
                
                // Check if there are more chats beyond the first page
                if syncedChats.count > Constants.Pagination.chatsPerPage {
                    self.hasMoreChats = true
                }
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
                
                // Set up pagination if there are more chats
                if sortedChats.count > 10 {
                    self.hasMoreChats = true
                    // Pagination token will be set by initializeCloudSync or setupPaginationForAppRestart
                }
            }
        }
    }
    
    /// Perform a full sync with the cloud
    func performFullSync() async {
        await MainActor.run {
            self.isSyncing = true
            self.syncErrors = []
        }
        
        let result = await cloudSync.syncAllChats()
        
        await MainActor.run {
            self.isSyncing = false
            self.lastSyncDate = Date()
            
            if !result.errors.isEmpty {
                self.syncErrors = result.errors
                // Show error recovery UI if there are sync errors
                self.showSyncErrorRecovery = true
            }
            
            // Use intelligent update that preserves pagination if user has loaded more pages
            if result.downloaded > 0 || result.uploaded > 0 {
                Task { @MainActor in
                    await self.updateChatsAfterSync()
                }
            }
        }
    }
    
    /// Set encryption key (for key rotation)
    func setEncryptionKey(_ key: String) async {
        print("🔐 ChatViewModel: setEncryptionKey called with key: \(key.prefix(12))...")
        do {
            let oldKey = EncryptionService.shared.getKey()
            print("📍 ChatViewModel: Old key: \(oldKey?.prefix(12) ?? "nil")...")
            try await EncryptionService.shared.setKey(key)
            
            await MainActor.run {
                self.encryptionKey = key
                self.showEncryptionSetup = false
            }
            
            print("🔑 ChatViewModel: Comparing keys - old: '\(oldKey ?? "nil")', new: '\(key)'")
            // If key changed, handle re-encryption
            if oldKey != key {
                print("🔄 ChatViewModel: Key changed, attempting to decrypt encrypted chats")
                
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
                print("🔓 ChatViewModel: Decrypted \(decryptedCount) chats with new key")
                
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
                let reencryptResult = await cloudSync.reencryptAndUploadChats()
                
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

