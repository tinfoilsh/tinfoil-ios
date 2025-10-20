import SwiftUI
import UIKit

/// Input area for typing messages, including model verification status and send button
struct MessageInputView: View {
    // MARK: - Constants
    fileprivate enum Layout {
        static let defaultHeight: CGFloat = 72
        static let minimumHeight: CGFloat = 72
        static let maximumHeight: CGFloat = 180
    }
    
    @Binding var messageText: String
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var authManager: AuthManager
    @State private var showErrorPopover = false
    @State private var textHeight: CGFloat = Layout.defaultHeight
    @ObservedObject private var settings = SettingsManager.shared
    var isKeyboardVisible: Bool = false

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
                             placeholderText: viewModel.currentChat?.messages.isEmpty ?? true ? "What's on your mind?" : "Message",
                             shouldFocusInput: viewModel.shouldFocusInput,
                             isLoading: viewModel.isLoading,
                             onFocusHandled: { viewModel.shouldFocusInput = false },
                             onSendMessage: { text in viewModel.sendMessage(text: text) })
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
                Group {
                    if #available(iOS 26, *) {
                        Button(action: handleButtonPress) {
                            Image(systemName: shouldShowMicrophone ?
                                  (viewModel.isRecording ? "mic.fill" : "mic") :
                                  (viewModel.isLoading ? "stop.fill" : "arrow.up"))
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .foregroundColor(isDarkMode ? Color.sendButtonForegroundDark : Color.sendButtonForegroundLight)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .clipShape(.circle)
                        .tint(isDarkMode ? Color.sendButtonBackgroundDark : Color.sendButtonBackgroundLight)
                    } else {
                        Button(action: handleButtonPress) {
                            ZStack {
                                Circle()
                                    .fill(shouldShowMicrophone ?
                                          (viewModel.isRecording ? Color.red : (isDarkMode ? Color.white : Color.primary)) :
                                          (isDarkMode ? Color.sendButtonBackgroundDark : Color.sendButtonBackgroundLight))
                                    .frame(width: 32, height: 32)

                                Image(systemName: shouldShowMicrophone ?
                                      (viewModel.isRecording ? "mic.fill" : "mic") :
                                      (viewModel.isLoading ? "stop.fill" : "arrow.up"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(shouldShowMicrophone ?
                                                   (viewModel.isRecording ? .white : (isDarkMode ? .black : .white)) :
                                                   (isDarkMode ? Color.sendButtonForegroundDark : Color.sendButtonForegroundLight))
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .padding(.vertical, 8)
        }
        .background {
            if #available(iOS 26, *) {
                RoundedRectangle(cornerRadius: 26)
                    .fill(.thickMaterial)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, isKeyboardVisible ? 12 : 0)
        .background {
            if #available(iOS 26, *) {
                Color.chatBackground(isDarkMode: isDarkMode)
                    .ignoresSafeArea()
            }
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
    var shouldFocusInput: Bool
    var isLoading: Bool
    var onFocusHandled: () -> Void
    var onSendMessage: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = false
        textView.scrollsToTop = false
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 2, bottom: 8, right: 5)
        textView.textContainer.lineFragmentPadding = 0
        textView.tintColor = UIColor.systemBlue

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
        context.coordinator.parent = self
        let isCurrentlyEditing = context.coordinator.isEditing

        if shouldFocusInput && !context.coordinator.hasFocusedFromFlag {
            context.coordinator.hasFocusedFromFlag = true
            DispatchQueue.main.async {
                if !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
                self.onFocusHandled()
            }
        } else if !shouldFocusInput {
            context.coordinator.hasFocusedFromFlag = false
        }

        if text.isEmpty && !isCurrentlyEditing && uiView.textColor != .lightGray {
            uiView.text = placeholderText
            uiView.textColor = .lightGray
        } else if text.isEmpty && isCurrentlyEditing {
            if uiView.textColor == .lightGray {
                uiView.text = ""
                uiView.textColor = UIColor { traitCollection in
                    return traitCollection.userInterfaceStyle == .dark ? .white : .black
                }
            }
        } else if !text.isEmpty && uiView.textColor == .lightGray {
            uiView.text = text
            uiView.textColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark ? .white : .black
            }
        } else if !text.isEmpty && uiView.text != text && uiView.textColor != .lightGray {
            uiView.text = text
        }

        uiView.isEditable = true

        let size = uiView.sizeThatFits(CGSize(width: uiView.frame.width, height: CGFloat.greatestFiniteMagnitude))
        let newHeight = min(MessageInputView.Layout.maximumHeight, max(MessageInputView.Layout.minimumHeight, size.height))

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
        var hasFocusedFromFlag = false

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }
        
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Check if Enter key was pressed (without Shift)
            if text == "\n" {
                // Check if this is running on Mac (iOS app on Mac)
                let isMac = ProcessInfo.processInfo.isiOSAppOnMac
                
                if isMac {
                    let currentText = textView.text ?? ""
                    let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !trimmedText.isEmpty && !parent.isLoading {
                        parent.onSendMessage(trimmedText)

                        textView.text = ""
                        parent.text = ""
                        parent.textHeight = MessageInputView.Layout.defaultHeight

                        textView.text = parent.placeholderText
                        textView.textColor = .lightGray

                        textView.resignFirstResponder()
                    }

                    return false
                }
            }
            
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
    }
} 
