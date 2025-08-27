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
            // Load saved chats from UserDefaults but don't select them
            let savedChats = Chat.loadFromDefaults(userId: currentUserId)
            chats = savedChats
            
            // Create a new chat directly and set it as current
            let newChat = Chat.create(
                modelType: currentModel,
                language: nil,
                userId: currentUserId
            )
            chats.insert(newChat, at: 0)
            currentChat = newChat
        } else {
            // For non-authenticated users, just create a single chat without saving
            let newChat = Chat.create(modelType: currentModel)
            currentChat = newChat
            chats = [newChat]
            
        }
        
        // Setup app lifecycle observers
        setupAppLifecycleObservers()
    }
    
    deinit {
        // Remove app lifecycle observers
        NotificationCenter.default.removeObserver(self)
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
        
        Task {
            let newChat: Chat
            
            // Use timestamp-based ID for authenticated users (for cloud sync)
            if authManager?.isAuthenticated == true {
                do {
                    newChat = try await Chat.createWithTimestampId(
                        modelType: modelType ?? currentModel,
                        language: language,
                        userId: currentUserId
                    )
                } catch {
                    // Fallback to UUID if ID generation fails
                    newChat = Chat.create(
                        modelType: modelType ?? currentModel,
                        language: language,
                        userId: currentUserId
                    )
                }
            } else {
                // Use regular UUID for anonymous users
                newChat = Chat.create(
                    modelType: modelType ?? currentModel,
                    language: language,
                    userId: currentUserId
                )
            }
            
            chats.insert(newChat, at: 0)
            // Select the new chat
            selectChat(newChat)
            // Request focus for the input when starting a new conversation
            shouldFocusInput = true
        }
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
        
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        // Update UI state
        isLoading = true
        
        // Create and add user message
        let userMessage = Message(role: .user, content: text)
        addMessage(userMessage)
        
        // If this is the first message, generate a title for the chat
        if var chat = currentChat, chat.messages.count == 1 {
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
        
        // Store the current chat ID to detect if it changes during streaming
        let streamChatId = currentChat?.id
        
        // Cancel any existing task
        currentTask?.cancel()
        
        // Create and start a new task for the streaming request
        currentTask = Task {
            // Begin background task to allow stream to complete if app goes to background
            var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "CompleteStreamingResponse") {
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
                    let maxWaitTime = 30.0 // 30 seconds timeout
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
                        // Exit if the chat has changed
                        guard self.currentChat?.id == streamChatId else { return }
                        
                        if var chat = self.currentChat,
                           !chat.messages.isEmpty,
                           let lastIndex = chat.messages.indices.last {
                            
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
                        // End streaming tracking for cloud sync
                        self.streamingTracker.endStreaming(chat.id)
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
                        // End streaming tracking for cloud sync
                        self.streamingTracker.endStreaming(chat.id)
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
    
    /// Adds a message to the current chat
    private func addMessage(_ message: Message) {
        guard var chat = currentChat else { return }
        
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
        }
    }
    
    /// Saves chats to UserDefaults and triggers cloud backup
    private func saveChats() {
        // Save chats for all authenticated users
        if hasChatAccess {
            let nonEmptyChats = chats.filter { !$0.messages.isEmpty }
            Chat.saveToDefaults(nonEmptyChats, userId: currentUserId)
            
            // Trigger cloud backup for the current chat if it has messages
            if let currentChat = currentChat, !currentChat.messages.isEmpty {
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
        
        // Clear encryption key reference
        encryptionKey = nil
    }
    
    /// Handle sign-in by loading user's saved chats
    func handleSignIn() {
        if hasChatAccess, let userId = currentUserId {
            
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
                        
                        // After sync completes, check if we have chats
                        await MainActor.run {
                            if self.chats.isEmpty {
                                self.createNewChat()
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
            
            // We have an encryption key, initialize cloud sync
            Task {
                await initializeCloudSync()
                
                // After sync completes, check if we have chats
                await MainActor.run {
                    if self.chats.isEmpty {
                        self.createNewChat()
                    } else {
                        // Select the most recent chat or create new
                        if let mostRecent = self.chats.first {
                            self.currentChat = mostRecent
                        } else {
                            self.createNewChat()
                        }
                    }
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
            
            // Perform initial sync
            await performFullSync()
        } catch {
            await MainActor.run {
                self.syncErrors.append(error.localizedDescription)
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
            
            // Reload chats after sync
            if let userId = self.currentUserId {
                let syncedChats = Chat.loadFromDefaults(userId: userId)
                if !syncedChats.isEmpty {
                    self.chats = syncedChats
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

