import SwiftUI
import UIKit
import PhotosUI

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

    // Check if audio input should be shown
    private var showAudioButton: Bool {
        hasPremiumAccess && AppConfig.shared.audioModel != nil
    }

    // State for pulsing animation
    @State private var isPulsing = false

    // Attachment picker state
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    // Binding to show audio error alert
    private var showAudioError: Binding<Bool> {
        Binding(
            get: { viewModel.audioError != nil },
            set: { if !$0 { viewModel.audioError = nil } }
        )
    }

    private var showAttachmentError: Binding<Bool> {
        Binding(
            get: { viewModel.attachmentError != nil },
            set: { if !$0 { viewModel.attachmentError = nil } }
        )
    }

    @ViewBuilder
    var body: some View {
        inputContent
            .alert("Microphone Access Required", isPresented: $viewModel.showMicrophonePermissionAlert) {
                Button("Open Settings") {
                    openSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To use voice input, please enable microphone access in Settings.")
            }
            .alert("Transcription Error", isPresented: showAudioError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.audioError ?? "An error occurred")
            }
            .alert("Attachment Error", isPresented: showAttachmentError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.attachmentError ?? "An error occurred")
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView { url, fileName in
                    viewModel.addDocumentAttachment(url: url, fileName: fileName)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        let fileName = "Photo.jpg"
                        viewModel.addImageAttachment(data: data, fileName: fileName)
                    }
                    selectedPhotoItem = nil
                }
            }
    }

    @ViewBuilder
    private var inputContent: some View {
        if #available(iOS 26, *) {
            // iOS 26+ with liquid glass effect
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

                    attachButton

                    webSearchButton

                    // Microphone button
                    if showAudioButton {
                        Button(action: handleAudioButtonTap) {
                            ZStack {
                                if viewModel.isRecording {
                                    // Pulsating background when recording
                                    Circle()
                                        .fill(Color.red.opacity(0.2))
                                        .frame(width: 44, height: 44)
                                        .scaleEffect(isPulsing ? 1.1 : 0.9)
                                        .animation(
                                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                            value: isPulsing
                                        )
                                }
                                
                                Group {
                                    if viewModel.isTranscribing {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                                            .font(.system(size: 20)) // Increased size as requested
                                    }
                                }
                                .frame(width: 32, height: 32)
                                .foregroundColor(viewModel.isRecording ? .red : .secondary)
                            }
                            // Restrict button layout size to match send button (32x32)
                            // so the larger pulsating circle doesn't affect bar height
                            .frame(width: 32, height: 32)
                        }
                        .onChange(of: viewModel.isRecording) { _, isRecording in
                            isPulsing = isRecording
                        }
                        .disabled(viewModel.isLoading || viewModel.isTranscribing)
                        .padding(.trailing, 4)
                    }

                    Button(action: sendOrCancelMessage) {
                        Image(systemName: viewModel.isLoading ? "stop.fill" : "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .foregroundColor(isDarkMode ? Color.sendButtonForegroundDark : Color.sendButtonForegroundLight)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .clipShape(.circle)
                    .tint(isDarkMode ? Color.sendButtonBackgroundDark : Color.sendButtonBackgroundLight)
                    .padding(.trailing, 8)
                }
                .padding(.vertical, 8)
            }
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
            .padding(.horizontal, 12)
            .padding(.bottom, isKeyboardVisible ? 12 : 0)
        } else {
            // Older iOS with material effect
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

                    attachButton

                    webSearchButton

                    // Microphone button
                    if showAudioButton {
                        Button(action: handleAudioButtonTap) {
                            ZStack {
                                if viewModel.isRecording {
                                    // Pulsating background when recording
                                    Circle()
                                        .fill(Color.red.opacity(0.2))
                                        .frame(width: 44, height: 44)
                                        .scaleEffect(isPulsing ? 1.1 : 0.9)
                                        .animation(
                                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                            value: isPulsing
                                        )
                                }
                                
                                Group {
                                    if viewModel.isTranscribing {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                                            .font(.system(size: 20)) // Increased size as requested
                                    }
                                }
                                .frame(width: 32, height: 32)
                                .foregroundColor(viewModel.isRecording ? .red : .secondary)
                            }
                            // Restrict button layout size to match send button (32x32)
                            // so the larger pulsating circle doesn't affect bar height
                            .frame(width: 32, height: 32)
                        }
                        .onChange(of: viewModel.isRecording) { _, isRecording in
                            isPulsing = isRecording
                        }
                        .disabled(viewModel.isLoading || viewModel.isTranscribing)
                        .padding(.trailing, 4)
                    }

                    Button(action: sendOrCancelMessage) {
                        ZStack {
                            Circle()
                                .fill(isDarkMode ? Color.sendButtonBackgroundDark : Color.sendButtonBackgroundLight)
                                .frame(width: 32, height: 32)

                            Image(systemName: viewModel.isLoading ? "stop.fill" : "arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isDarkMode ? Color.sendButtonForegroundDark : Color.sendButtonForegroundLight)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .padding(.vertical, 8)
            }
            .background {
                RoundedRectangle(cornerRadius: 26)
                    .fill(.thickMaterial)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, isKeyboardVisible ? 12 : 0)
        }
    }

    @ViewBuilder
    private var attachButton: some View {
        Menu {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label("Photo Library", systemImage: "photo")
            }
            Button {
                showDocumentPicker = true
            } label: {
                Label("Document", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
        }
        .disabled(viewModel.isLoading || viewModel.isProcessingAttachment)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var webSearchButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.isWebSearchEnabled.toggle()
                settings.webSearchEnabled = viewModel.isWebSearchEnabled
            }
        }) {
            if viewModel.isWebSearchEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Search")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentPrimary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundColor(.accentPrimary)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.trailing, 8)
    }

    private func sendOrCancelMessage() {
        if viewModel.isLoading {
            viewModel.cancelGeneration()
        } else if !messageText.isEmpty || !viewModel.pendingAttachments.isEmpty {
            viewModel.sendMessage(text: messageText)
            messageText = ""
            textHeight = Layout.defaultHeight
        }
    }

    private func handleAudioButtonTap() {
        Task {
            if viewModel.isRecording {
                if let transcription = await viewModel.stopAudioRecordingAndTranscribe() {
                    if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messageText = transcription
                    } else {
                        messageText += " " + transcription
                    }
                }
            } else {
                await viewModel.startAudioRecording()
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
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
            if uiView.text.isEmpty && uiView.textColor == .lightGray {
                uiView.text = ""
                uiView.textColor = UIColor { traitCollection in
                    return traitCollection.userInterfaceStyle == .dark ? .white : .black
                }
            } else if !uiView.text.isEmpty && uiView.textColor != .lightGray {
                self.text = uiView.text
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
            DispatchQueue.main.async {
                self.textHeight = newHeight
            }
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
