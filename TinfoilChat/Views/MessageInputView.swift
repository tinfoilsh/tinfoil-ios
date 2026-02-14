import SwiftUI
import UIKit
import PhotosUI
import RevenueCat
import RevenueCatUI

/// Input area for typing messages, including attachments and send button
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
    @State private var showAddSheet = false
    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingPickerAction: PickerAction?

    private enum PickerAction {
        case camera, photos, files
    }

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
            .sheet(isPresented: $showPhotoPicker, onDismiss: processSelectedPhotos) {
                NavigationStack {
                    PhotosPicker(selection: $selectedPhotoItems, matching: .images) {
                        Text("Select Photos")
                    }
                    .photosPickerStyle(.inline)
                    .navigationTitle("Select Photos")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showPhotoPicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView { image in
                    if let data = image.jpegData(compressionQuality: CGFloat(Constants.Attachments.imageCompressionQuality)) {
                        viewModel.addImageAttachment(data: data, fileName: "Camera Photo.jpg")
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showAddSheet, onDismiss: {
                guard let action = pendingPickerAction else { return }
                pendingPickerAction = nil
                switch action {
                case .camera: showCamera = true
                case .photos: showPhotoPicker = true
                case .files: showDocumentPicker = true
                }
            }) {
                AddToSheetView(
                    viewModel: viewModel,
                    isDarkMode: isDarkMode,
                    onCamera: {
                        pendingPickerAction = .camera
                        showAddSheet = false
                    },
                    onPhotos: {
                        pendingPickerAction = .photos
                        showAddSheet = false
                    },
                    onFiles: {
                        pendingPickerAction = .files
                        showAddSheet = false
                    }
                )
                .environmentObject(authManager)
                .presentationDetents([.height(340)])
                .presentationBackground(isDarkMode ? Color(hex: "161616") : Color(UIColor.systemGroupedBackground))
            }
    }

    @ViewBuilder
    private var inputContent: some View {
        if #available(iOS 26, *) {
            // iOS 26+ with liquid glass effect
            VStack(spacing: 0) {
                // Attachment preview bar
                if !viewModel.pendingAttachments.isEmpty {
                    AttachmentPreviewBar(
                        attachments: viewModel.pendingAttachments,
                        thumbnails: viewModel.pendingImageThumbnails,
                        onRemove: { id in viewModel.removePendingAttachment(id: id) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

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

                // Bottom row with action buttons
                HStack {
                    attachButton

                    webSearchButton

                    Spacer()

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
                                            .font(.system(size: 20))
                                    }
                                }
                                .frame(width: 32, height: 32)
                                .foregroundColor(viewModel.isRecording ? .red : .secondary)
                            }
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
                // Attachment preview bar
                if !viewModel.pendingAttachments.isEmpty {
                    AttachmentPreviewBar(
                        attachments: viewModel.pendingAttachments,
                        thumbnails: viewModel.pendingImageThumbnails,
                        onRemove: { id in viewModel.removePendingAttachment(id: id) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

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

                // Bottom row with action buttons
                HStack {
                    attachButton

                    webSearchButton

                    Spacer()

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
                                            .font(.system(size: 20))
                                    }
                                }
                                .frame(width: 32, height: 32)
                                .foregroundColor(viewModel.isRecording ? .red : .secondary)
                            }
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
        Button {
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
        }
        .disabled(viewModel.isLoading || viewModel.isProcessingAttachment)
        .padding(.leading, 8)
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
                    Text("Web Search")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundColor(.primary)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.leading, 8)
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

    private func processSelectedPhotos() {
        let items = selectedPhotoItems
        selectedPhotoItems = []
        for (index, item) in items.enumerated() {
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let fileName = items.count > 1 ? "Photo \(index + 1).jpg" : "Photo.jpg"
                    viewModel.addImageAttachment(data: data, fileName: fileName)
                }
            }
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

/// Bottom sheet presented from the "+" button with attachment options and model selector
struct AddToSheetView: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @EnvironmentObject private var authManager: AuthManager
    let isDarkMode: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPremiumModal = false

    private var availableModels: [ModelType] {
        AppConfig.shared.filteredModelTypes(
            isAuthenticated: authManager.isAuthenticated,
            hasActiveSubscription: authManager.hasActiveSubscription
        )
    }

    private func canUseModel(_ model: ModelType) -> Bool {
        model.isFree || (authManager.isAuthenticated && authManager.hasActiveSubscription)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Attachment buttons
                HStack(spacing: 12) {
                    if viewModel.currentModel.isMultimodal {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            attachmentButton(icon: "camera", label: "Camera") {
                                onCamera()
                            }
                        }
                        attachmentButton(icon: "photo.on.rectangle", label: "Photos") {
                            onPhotos()
                        }
                    }
                    attachmentButton(icon: "doc.badge.arrow.up", label: "Files") {
                        onFiles()
                    }
                }
                .padding(.horizontal, 20)

                Divider()
                    .padding(.horizontal, 20)

                // Model selector
                Text("Select a Model")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, -12)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(availableModels) { model in
                                ModelTab(
                                    model: model,
                                    isSelected: viewModel.currentModel.id == model.id,
                                    isDarkMode: isDarkMode,
                                    isEnabled: canUseModel(model),
                                    showPricingLabel: !(authManager.isAuthenticated && authManager.hasActiveSubscription),
                                    style: .regular
                                ) {
                                    if canUseModel(model) {
                                        viewModel.changeModel(to: model)
                                    } else {
                                        if authManager.isAuthenticated, let clerkUserId = authManager.localUserData?["id"] as? String {
                                            Purchases.shared.attribution.setAttributes(["clerk_user_id": clerkUserId])
                                        }
                                        showPremiumModal = true
                                    }
                                }
                                .id(model.id)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo(viewModel.currentModel.id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background((isDarkMode ? Color(hex: "161616") : Color(UIColor.systemGroupedBackground)).ignoresSafeArea())
            .navigationTitle("Add to Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
            .sheet(isPresented: $showPremiumModal) {
                PaywallView(displayCloseButton: true)
                    .onPurchaseCompleted { _ in
                        showPremiumModal = false
                    }
                    .onDisappear {
                        Task {
                            await authManager.fetchSubscriptionStatus()
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func attachmentButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
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
