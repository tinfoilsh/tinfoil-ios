//
//  ChatViewModel.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

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
    
    // Verification properties
    @Published var isVerifying: Bool = false
    @Published var isVerified: Bool = false
    @Published var verificationError: String? = nil
    
    // Model properties
    @Published var currentModel: ModelType
    
    // View state for verifier
    @Published var verifierView: VerifierView?
    
    // Rate limiting properties
    @Published var isRateLimited: Bool = false
    @Published var messagesRemaining: Int = Constants.RateLimits.freeUserMaxMessages
    
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
        // Initialize with first available model if current model is not set
        self.currentModel = AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first!
        
        // Store auth manager reference
        self.authManager = authManager
        
        // If user is authenticated, load saved chats from UserDefaults if available
        if let auth = authManager, auth.isAuthenticated {
            let savedChats = Chat.loadFromDefaults(userId: currentUserId)
            if !savedChats.isEmpty {
                chats = savedChats
                // Select the first chat and load its initial page
                selectChat(chats.first!) // Force unwrap okay here as we checked !isEmpty
            } else {
                createNewChat() // Creates an empty chat, selectChat is called within
            }
        } else {
            // For non-authenticated users, just create a single chat without saving
            let newChat = Chat.create(modelType: currentModel)
            currentChat = newChat
            chats = [newChat]
            
            // Update rate limit status
            updateRateLimitStatus()
        }
        
        // Initialize Tinfoil client and verify enclave
        setupTinfoilClient()
    }
    
    private func setupTinfoilClient() {
        // Set verification status to "in progress" at the start
        self.isVerifying = true
        
        Task {
            do {
                // Get authentication status
                let isAuthenticated = authManager?.isAuthenticated ?? false
                let hasSubscription = authManager?.hasActiveSubscription ?? false
                
                // Get appropriate API key based on model and authentication status
                let apiKey = await AppConfig.shared.getApiKey(
                    forModel: currentModel,
                    isAuthenticated: isAuthenticated,
                    hasSubscription: hasSubscription
                )
                
                // Ensure we have a valid API key
                guard !apiKey.isEmpty else {
                    throw NSError(
                        domain: "TinfoilChat", 
                        code: 401,
                        userInfo: [NSLocalizedDescriptionKey: "API key not available. Please check your subscription."]
                    )
                }
                
                // Create a single Tinfoil client instance using the current model settings
                // with non-blocking verification callback
                client = try await TinfoilAI.create(
                    apiKey: apiKey,
                    githubRepo: currentModel.repoName,
                    enclaveURL: currentModel.enclave,
                    nonblockingVerification: { [weak self] passed in
                        Task { @MainActor in
                            guard let self = self else { return }
                            
                            // Update verification state based on callback result
                            self.isVerifying = false
                            self.isVerified = passed
                            
                            if passed {
                                self.verificationError = nil
                                print("Tinfoil: Non-blocking verification successful for model: \(self.currentModel.displayName)")
                            } else {
                                self.verificationError = "Enclave verification failed. The connection may not be secure."
                                print("Tinfoil: Non-blocking verification failed for model: \(self.currentModel.displayName)")
                            }
                        }
                    }
                )
                
                // If we get here, verification was successful 
                // Tinfoil verifies during init and throws error if it fails
                self.isVerifying = false
                self.isVerified = true

            } catch {
                self.isVerifying = false
                self.isVerified = false
                self.verificationError = error.localizedDescription
                print("Tinfoil: setup Error: \(error)")
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Creates a new chat and sets it as the current chat
    func createNewChat(language: String? = nil, modelType: ModelType? = nil) {
        // Allow creating new chats for all authenticated users
        guard hasChatAccess else { return }
        
        let newChat = Chat.create(
            modelType: modelType ?? currentModel,
            language: language,
            userId: currentUserId
        )
        chats.insert(newChat, at: 0)
        // Select the new chat
        selectChat(newChat)
        saveChats()
    }
    
    /// Selects a chat as the current chat
    func selectChat(_ chat: Chat) {
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
            
            // If the deleted chat was the current chat, select another one
            if currentChat?.id == deletedChat.id {
                currentChat = chats.first
            }
            
            saveChats()
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
        
        // Check rate limiting only for users who are not authenticated
        let isAuthenticated = authManager?.isAuthenticated ?? false
        if !isAuthenticated {
            // Check if user has exceeded rate limit
            let rateLimitManager = RateLimitManager.shared
            if rateLimitManager.isRateLimited {
                isRateLimited = true
                return
            }
            
            // Increment message count
            if rateLimitManager.incrementAndCheckLimit() {
                isRateLimited = true
            }
            
            // Update messages remaining
            updateRateLimitStatus()
        }
        
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
        }
        
        // Cancel any existing task
        currentTask?.cancel()
        
        // Create and start a new task for the streaming request
        currentTask = Task {
            do {
                guard let client = client else {
                    throw NSError(domain: "TinfoilChat", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "TinfoilAI client not available"])
                }
                
                // Create the stream with proper parameters
                let modelId = AppConfig.shared.getModelConfig(currentModel)?.modelId ?? ""
                
                // Add system message first with language preference
                var systemPrompt = AppConfig.shared.systemPrompt
                
                // Replace MODEL_NAME placeholder with current model name
                systemPrompt = systemPrompt.replacingOccurrences(of: "<MODEL_NAME>", with: currentModel.fullName)
                
                // Replace language placeholder
                if let chat = currentChat, let language = chat.language {
                    systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: language)
                } else {
                    systemPrompt = systemPrompt.replacingOccurrences(of: "{LANGUAGE}", with: "English")
                }
                
                // Build messages array inline
                var messages: [ChatQuery.ChatCompletionMessageParam] = [
                    .system(.init(content: .textContent(systemPrompt)))
                ]
                
                // Add conversation messages
                let messagesForContext = Array(self.messages.suffix(AppConfig.shared.maxMessagesPerRequest))
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
                
                for try await chunk in stream {
                    if let content = chunk.choices.first?.delta.content {
                        // Update UI on main thread
                        await MainActor.run {
                            if var chat = self.currentChat {
                                // Check for think tag start
                                if content.contains("<think>") {
                                    thinkStartTime = Date()
                                    hasThinkTag = true
                                }
                                
                                // Check for think tag end
                                if hasThinkTag && content.contains("</think>") {
                                    if let startTime = thinkStartTime {
                                        let generationTime = Date().timeIntervalSince(startTime)
                                        chat.messages[chat.messages.count - 1].generationTimeSeconds = generationTime
                                    }
                                    hasThinkTag = false
                                    thinkStartTime = nil
                                }
                                
                                // Append the new content
                                chat.messages[chat.messages.count - 1].content += content
                                self.updateChat(chat) // Saves the full chat
                            }
                        }
                    }
                }
                
                // Mark as complete
                await MainActor.run {
                    self.isLoading = false
                    
                    // If we still have an open think tag, calculate the time
                    if hasThinkTag, let startTime = thinkStartTime,
                       var chat = self.currentChat,
                       !chat.messages.isEmpty {
                        let generationTime = Date().timeIntervalSince(startTime)
                        chat.messages[chat.messages.count - 1].generationTimeSeconds = generationTime
                        self.updateChat(chat)
                    }
                    
                    // Mark the chat as no longer having an active stream
                    if var chat = self.currentChat {
                        chat.hasActiveStream = false
                        self.updateChat(chat)
                    }
                }
            } catch {
                print("Tinfoil: Error in chat stream: \(error)")
                // Handle error
                await MainActor.run {
                    self.isLoading = false
                    
                    // Mark the chat as no longer having an active stream
                    if var chat = self.currentChat {
                        chat.hasActiveStream = false
                        self.updateChat(chat)
                    }
                    
                    if var chat = self.currentChat,
                       !chat.messages.isEmpty {
                        // Update the last message in the full chat
                        chat.messages[chat.messages.count - 1].content = "Error: The Internet connection appears to be offline."
                        
                        // Format a more user-friendly error message based on the error type
                        let userFriendlyError = formatUserFriendlyError(error)
                        chat.messages[chat.messages.count - 1].streamError = userFriendlyError
                        
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
                 NSURLErrorDataNotAllowed,
                 NSURLErrorNetworkConnectionLost:
                return "The Internet connection appears to be offline."
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
        }
        
        self.showVerifierSheet = false
    }
    
    /// Shows the verifier sheet with current verification state
    func showVerifier() {
        // Create verifier view with current verification state
        verifierView = VerifierView(
            initialVerificationState: isVerified ? true : nil,
            initialError: verificationError
        )
        showVerifierSheet = true
    }
    
    /// Dismisses the verifier sheet
    func dismissVerifier() {
        self.showVerifierSheet = false
        self.verifierView = nil
    }
    
    // MARK: - Speech-to-Text Methods
    
    /// Starts speech-to-text recording
    func startSpeechToText() {
        Task {
            do {
                // Request microphone permission
                let permissionGranted = await requestMicrophonePermission()
                guard permissionGranted else {
                    print("ChatViewModel: Microphone permission denied")
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
                    print("ChatViewModel: Started audio recording to \(url.lastPathComponent)")
                }
                
            } catch {
                print("ChatViewModel: Failed to start recording: \(error)")
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
            convertAudioToMP3AndProcess(sourceURL: recordingURL)
        } else {
            print("ChatViewModel: No recording URL available")
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
    
    /// Converts recorded audio to MP3 format and processes it
    private func convertAudioToMP3AndProcess(sourceURL: URL) {
        Task {
            do {
                // For now, we'll read the M4A file directly as audio data
                // In a real implementation, you might want to convert to MP3 format
                let audioData = try Data(contentsOf: sourceURL)
                
                print("ChatViewModel: Successfully read \(audioData.count) bytes of audio data")
                
                // Process the actual audio data
                processSpeechToTextWithAudio(audioData: audioData)
                
                // Clean up the temporary file
                try FileManager.default.removeItem(at: sourceURL)
                
            } catch {
                print("ChatViewModel: Failed to read audio file: \(error)")
                await MainActor.run {
                    // Handle error - could publish error state
                    print("ChatViewModel: Audio processing error: \(error)")
                }
            }
        }
    }
    
    /// Processes the recorded audio data for speech-to-text conversion using TinfoilAI client
    /// - Parameter audioData: The recorded audio data to be transcribed
    func processSpeechToTextWithAudio(audioData: Data) {
        // TODO: Replace with actual tinfoilai client speech-to-text API call
        // This should use the existing TinfoilAI client instance
        
        print("ChatViewModel: Processing \(audioData.count) bytes of recorded audio data...")
        
        // Simulate API processing delay
        Task {
            do {
                guard let client = client else {
                    throw NSError(domain: "TinfoilChat", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "TinfoilAI client not available"])
                }
                
                // TODO: Use actual TinfoilAI speech-to-text endpoint
                // Example: let transcription = try await client.speechToText(audioData: audioData)
                
                // Simulate processing delay
                try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                
                // Simulate successful transcription response with real audio data info
                let simulatedTranscription = "This is a test transcription from \(audioData.count) bytes of recorded audio"
                
                await MainActor.run {
                    print("ChatViewModel: Transcription completed: \(simulatedTranscription)")
                    
                    // Set the transcribed text that MessageInputView can observe
                    self.transcribedText = simulatedTranscription
                }
                
            } catch {
                await MainActor.run {
                    print("ChatViewModel: Speech-to-text error: \(error)")
                    // Handle error - could publish error state
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
    
    /// Saves chats to UserDefaults
    private func saveChats() {
        // Save chats for all authenticated users
        if hasChatAccess {
            Chat.saveToDefaults(chats, userId: currentUserId)
        }
    }
    
    /// Updates rate limiting status for free users
    private func updateRateLimitStatus() {
        // If user is authenticated, they are not rate limited
        let isAuthenticated = authManager?.isAuthenticated ?? false
        if isAuthenticated {
            isRateLimited = false
            messagesRemaining = Constants.RateLimits.freeUserMaxMessages
            return
        }
        
        // Get status from rate limit manager for non-authenticated users
        let rateLimitManager = RateLimitManager.shared
        isRateLimited = rateLimitManager.isRateLimited
        messagesRemaining = rateLimitManager.messagesRemaining
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
                self.verificationError = isAuthenticated 
                    ? "Premium model requires an active subscription." 
                    : "Premium model requires authentication."
                
                // Don't proceed with model change if not authorized
                return
            }
        }
        
        // Update model settings
        self.currentModel = modelType
        AppConfig.shared.currentModel = modelType
        
        // Update the current chat's model if requested
        if shouldUpdateChat, var chat = currentChat {
            chat.modelType = modelType
            updateChat(chat)
        }
        
        // Clear the current client
        self.client = nil
        
        // Reset verification state
        self.isVerified = false
        self.isVerifying = false
        self.verificationError = nil
        
        // Reinitialize the Tinfoil client for the new model
        setupTinfoilClient()


        // Notify of successful model change with haptic feedback
        Chat.triggerSuccessFeedback()
    }
    
    // MARK: - Authentication & Model Access
    
    /// Updates the current model if needed based on auth status changes
    func updateModelBasedOnAuthStatus(isAuthenticated: Bool, hasActiveSubscription: Bool) {
        // Clear any cached API key when auth status changes
        APIKeyManager.shared.clearApiKey()
        
        // Get available models based on auth status
        let availableModels = AppConfig.shared.filteredModelTypes(
            isAuthenticated: isAuthenticated,
            hasActiveSubscription: hasActiveSubscription
        )
        
        // If current model is not available, switch to first available model
        if !availableModels.contains(where: { $0.id == currentModel.id }), let firstModel = availableModels.first {
            changeModel(to: firstModel)
        }
        
        // Update rate limit status - this will reset rate limiting for authenticated users
        updateRateLimitStatus()
        
        // If authenticated user just logged in, clear rate limiting state
        if isAuthenticated {
            isRateLimited = false
            RateLimitManager.shared.resetCounter()
            print("Tinfoil: Rate limiting disabled for authenticated user")
        }
        
        // If user upgraded to premium, load saved chats if any
        if isAuthenticated && hasActiveSubscription && chats.count <= 1 {
            let savedChats = Chat.loadFromDefaults(userId: currentUserId)
            if !savedChats.isEmpty {
                chats = savedChats
                if let currentChatId = currentChat?.id, 
                   let existingChat = chats.first(where: { $0.id == currentChatId }) {
                    // Keep current chat if it exists in saved chats
                    selectChat(existingChat)
                } else {
                    // Otherwise select first chat
                    selectChat(chats.first!)
                }
            }
        }
    }
    
    /// Handle sign-out by clearing current chats but preserving them in storage
    func handleSignOut() {
        // Save current chats before clearing them (they're already associated with the user ID)
        if hasChatAccess {
            saveChats()
        }
        
        // Clear current chats and create a new empty one
        chats = []
        let newChat = Chat.create(modelType: currentModel)
        currentChat = newChat
        chats = [newChat]
        
        // Update rate limit status for non-authenticated state
        updateRateLimitStatus()
    }
    
    /// Handle sign-in by loading user's saved chats
    func handleSignIn() {
        if hasChatAccess, let userId = currentUserId {
            let savedChats = Chat.loadFromDefaults(userId: userId)
            if !savedChats.isEmpty {
                chats = savedChats
                selectChat(chats.first!) // Select first chat
            } else {
                createNewChat() // Create new chat if no saved chats exist
            }
        }
        
        // Update rate limit status for authenticated state
        updateRateLimitStatus()
    }
}
