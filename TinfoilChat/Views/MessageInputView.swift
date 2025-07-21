import SwiftUI
import UIKit

/// Input area for typing messages, including model verification status and send button
struct MessageInputView: View {
    // MARK: - Constants
    fileprivate enum Layout {
        static let defaultHeight: CGFloat = 80
        static let minimumHeight: CGFloat = 80
        static let maximumHeight: CGFloat = 180
    }
    
    @Binding var messageText: String
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var authManager: AuthManager
    @State private var showErrorPopover = false
    @State private var textHeight: CGFloat = Layout.defaultHeight
    @ObservedObject private var settings = SettingsManager.shared
    
    // Haptic feedback generator
    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    
    private var isDarkMode: Bool { colorScheme == .dark }
    
    // Check for subscription status
    private var hasPremiumAccess: Bool {
        authManager.isAuthenticated && authManager.hasActiveSubscription
    }
    
    // Check only for authentication status
    private var isUserAuthenticated: Bool {
        authManager.isAuthenticated
    }
    
    // Determine which button to show
    private var shouldShowMicrophone: Bool {
        // TODO: make audio recording work
        // messageText.isEmpty && !viewModel.isLoading && viewModel.hasSpeechToTextAccess
        false
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Text input area
            CustomTextEditor(text: $messageText, 
                             textHeight: $textHeight, 
                             placeholderText: viewModel.currentChat?.messages.isEmpty ?? true ? "What's on your mind?" : "Message")
                .frame(height: textHeight)
                .padding(.horizontal)
            
            // Bottom row with shield and send button
            HStack {
                // Shield status indicator
                Button(action: {
                    viewModel.showVerifier()
                }) {
                    HStack {
                        Image(systemName: viewModel.isVerified && viewModel.verificationError == nil ? "lock.fill" : 
                                          viewModel.isVerifying ? "shield" : "exclamationmark.shield.fill")
                            .foregroundColor(viewModel.isVerified && viewModel.verificationError == nil ? .green : 
                                            viewModel.isVerifying ? .orange : .red)
                            .font(.caption)
                        if let error = viewModel.verificationError {
                            HStack(spacing: 4) {
                                Text("Verification failed")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                Button(action: {
                                    showErrorPopover.toggle()
                                }) {
                                    Image(systemName: "info.circle")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                .alert(isPresented: $showErrorPopover) {
                                    Alert(
                                        title: Text("Verification Error"),
                                        message: Text(error),
                                        dismissButton: .default(Text("OK"))
                                    )
                                }
                            }
                        } else {
                            Text(viewModel.verificationStatusMessage)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.leading)
                
                Spacer()
                
                // Send/Microphone button
                Button(action: handleButtonPress) {
                    ZStack {
                        Circle()
                            .fill(shouldShowMicrophone ? 
                                  (viewModel.isRecording ? Color.red : (isDarkMode ? Color.white : Color.primary)) :
                                  (isDarkMode ? Color.white : Color.primary))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: shouldShowMicrophone ? 
                              (viewModel.isRecording ? "mic.fill" : "mic") : 
                              (viewModel.isLoading ? "stop.fill" : "arrow.up"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(shouldShowMicrophone ? 
                                           (viewModel.isRecording ? .white : (isDarkMode ? .black : .white)) :
                                           (isDarkMode ? .black : .white))
                    }
                }
                .padding(.trailing, 24)
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            softHaptic.prepare()
        }
        .onChange(of: viewModel.transcribedText) { oldValue, newValue in
            if !newValue.isEmpty && newValue != oldValue {
                // Check if it's an error message (don't auto-send these)
                if newValue.contains("requires authentication") || newValue.contains("failed") {
                    // Show error message in text field for user to see
                    messageText = newValue
                    textHeight = Layout.defaultHeight
                } else {
                    // For successful transcriptions, the message is auto-sent by the ViewModel
                    // We don't need to do anything here since sendMessage is called directly
                }
                
                // Clear the transcribed text to prevent it from being processed again
                viewModel.transcribedText = ""
            }
        }
        .onChange(of: viewModel.messages.last?.content) { oldContent, newContent in
            if settings.hapticFeedbackEnabled,
               let old = oldContent,
               let new = newContent,
               old != new {
                let addedContent = String(new.dropFirst(old.count))
                if addedContent.count > 1 {
                    softHaptic.impactOccurred(intensity: 0.3)
                }
            }
        }
    }
    
    
    /// Handles the send button action - either sends a message or cancels generation
    private func sendOrCancelMessage() {
        if viewModel.isLoading {
            viewModel.cancelGeneration()
        } else if !messageText.isEmpty {
            viewModel.sendMessage(text: messageText)
            messageText = ""
            textHeight = Layout.defaultHeight // Reset height when message is sent
        }
    }
    
    private func handleButtonPress() {
        if shouldShowMicrophone {
            if viewModel.isRecording {
                viewModel.stopSpeechToText()
            } else {
                viewModel.startSpeechToText()
            }
        } else {
            sendOrCancelMessage()
        }
    }
}

/// Custom UIViewRepresentable for a properly managed text editor
struct CustomTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var textHeight: CGFloat
    var placeholderText: String
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = false
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 2, bottom: 8, right: 5) // Reduced left padding
        textView.textContainer.lineFragmentPadding = 0
        textView.tintColor = UIColor.systemBlue // Set cursor and selection color to blue
        
        // Initialize with placeholder or actual text
        if text.isEmpty {
            textView.text = placeholderText
            textView.textColor = .lightGray
        } else {
            textView.text = text
            textView.textColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark ? .white : .black
            }
        }
        
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        // Check if text field is currently being edited
        let isCurrentlyEditing = context.coordinator.isEditing
        
        // Only show placeholder if text is empty AND not currently being edited
        if text.isEmpty && !isCurrentlyEditing && uiView.textColor != .lightGray {
            // Text was cleared and we're not editing, show placeholder
            uiView.text = placeholderText
            uiView.textColor = .lightGray
        } else if text.isEmpty && isCurrentlyEditing {
            // Empty text but still editing, ensure we don't show placeholder
            if uiView.textColor == .lightGray {
                uiView.text = ""
                uiView.textColor = UIColor { traitCollection in
                    return traitCollection.userInterfaceStyle == .dark ? .white : .black
                }
            }
        } else if !text.isEmpty && uiView.textColor == .lightGray {
            // New text arrived, remove placeholder
            uiView.text = text
            uiView.textColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark ? .white : .black
            }
        } else if !text.isEmpty && uiView.text != text && uiView.textColor != .lightGray {
            // Text changed but not placeholder related
            uiView.text = text
        }
        
        // Update editable status
        uiView.isEditable = true
        
        // Calculate the new height
        let size = uiView.sizeThatFits(CGSize(width: uiView.frame.width, height: CGFloat.greatestFiniteMagnitude))
        let newHeight = min(MessageInputView.Layout.maximumHeight, max(MessageInputView.Layout.minimumHeight, size.height))
        
        // Only update height if it changed
        if textHeight != newHeight {
            textHeight = newHeight
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CustomTextEditor
        var isEditing = false
        
        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }
        
        func textViewDidChange(_ textView: UITextView) {
            // Only update if the text is not the placeholder
            if textView.textColor != .lightGray {
                parent.text = textView.text
                
                // Calculate and update the height
                let size = textView.sizeThatFits(CGSize(width: textView.frame.width, height: CGFloat.greatestFiniteMagnitude))
                let newHeight = min(MessageInputView.Layout.maximumHeight, max(MessageInputView.Layout.minimumHeight, size.height))
                
                if parent.textHeight != newHeight {
                    parent.textHeight = newHeight
                }
            }
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            // Clear placeholder when editing begins
            if textView.textColor == .lightGray {
                textView.text = ""
                textView.textColor = UIColor { traitCollection in
                    return traitCollection.userInterfaceStyle == .dark ? .white : .black
                }
            }
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            // Add placeholder if needed when editing ends
            if textView.text.isEmpty {
                textView.text = parent.placeholderText
                textView.textColor = .lightGray
            }
        }
        
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Check if the text will be empty after this change
            let currentText = textView.text as NSString
            let newText = currentText.replacingCharacters(in: range, with: text)
            
            // If text is becoming empty but we're still editing, don't show placeholder
            if newText.isEmpty && isEditing {
                // Let the deletion happen, but don't show placeholder yet
                // The placeholder will be shown in textViewDidEndEditing when focus is lost
                return true
            }
            
            return true
        }
    }
} 