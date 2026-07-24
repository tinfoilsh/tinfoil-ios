import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import RevenueCat
import RevenueCatUI

enum CameraPermissionAction: Equatable {
    case presentCamera
    case requestAccess
    case showSettingsAlert
}

func cameraPermissionAction(for status: AVAuthorizationStatus) -> CameraPermissionAction {
    switch status {
    case .authorized:
        return .presentCamera
    case .notDetermined:
        return .requestAccess
    case .denied, .restricted:
        return .showSettingsAlert
    @unknown default:
        return .showSettingsAlert
    }
}

/// Input area for typing messages, including attachments and send button
struct MessageInputView: View {
    // MARK: - Constants
    fileprivate enum Layout {
        static let defaultHeight: CGFloat = 72
        static let minimumHeight: CGFloat = 72
        static let maximumHeight: CGFloat = 180
        /// Drafts at or beyond these bounds cannot fit within `maximumHeight`
        /// at any supported text size, so the editor skips the full TextKit
        /// measurement pass that `sizeThatFits` would otherwise run over the
        /// entire draft on the main thread.
        static let overflowCharacterCount = 2_000
        static let overflowNewlineCount = 10
    }
    
    @Binding var messageText: String
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @EnvironmentObject private var authManager: AuthManager
    @State private var textHeight: CGFloat = Layout.defaultHeight
    /// Reflects whether the editor has grown beyond a single line, so callers
    /// can hide content that would otherwise be pushed off-screen.
    var isInputExpanded: Binding<Bool>? = nil
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
        AppConfig.shared.audioModel != nil
    }

    // State for pulsing animation
    @State private var isPulsing = false

    // Clears the editor's UITextView imperatively at send time, so the draft
    // disappears even while the editor keeps focus (queued sends don't
    // dismiss the keyboard) without depending on render timing.
    @State private var editorHandle = CustomTextEditorHandle()

    /// A draft that can actually be sent or queued right now: attachments
    /// all processed, plus either non-whitespace text or at least one
    /// attachment. Matches `sendMessage`'s own guards so the button never
    /// offers a send that would be rejected.
    private var hasSubmittableContent: Bool {
        guard attachmentsAreReadyToSend(viewModel.pendingAttachments) else { return false }
        return !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.pendingAttachments.isEmpty
    }

    /// While a response is streaming, the button stays a send button only
    /// while a sendable draft can actually be queued; with nothing
    /// submittable, or the queue already full, it reverts to a stop button
    /// so the stream can always be cancelled. Mirrors the webapp.
    private var showStopAction: Bool {
        viewModel.isLoading && (!hasSubmittableContent || viewModel.isMessageQueueFull)
    }

    private enum TrailingAction {
        case voice
        case send
        case stop
    }

    /// The trailing button doubles as voice input while the draft is empty
    /// and becomes the send button once the user enters text or attaches
    /// files; while a stream with nothing submittable is in flight it turns
    /// into a stop button. An active recording pins the voice role so the
    /// microphone can always be stopped, but a pending transcription yields
    /// to stop so an in-flight stream stays cancellable.
    private var trailingAction: TrailingAction {
        if showAudioButton && viewModel.isRecording {
            return .voice
        }
        if showStopAction { return .stop }
        if showAudioButton && viewModel.isTranscribing {
            return .voice
        }
        if showAudioButton,
           messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           viewModel.pendingAttachments.isEmpty {
            return .voice
        }
        return .send
    }

    private var trailingActionIconName: String {
        switch trailingAction {
        case .voice: return viewModel.isRecording ? "stop.fill" : "mic.fill"
        case .send: return "arrow.up"
        case .stop: return "stop.fill"
        }
    }

    private var trailingActionAccessibilityLabel: String {
        switch trailingAction {
        case .voice: return viewModel.isRecording ? "Stop recording" : "Voice input"
        case .send: return "Send message"
        case .stop: return "Stop generating"
        }
    }

    /// The send action greys out while a draft can't be dispatched because
    /// an attachment is still processing; voice greys out while a recording
    /// is being transcribed.
    private var isTrailingActionDisabled: Bool {
        switch trailingAction {
        case .voice: return viewModel.isTranscribing
        case .send: return !attachmentsAreReadyToSend(viewModel.pendingAttachments)
        case .stop: return false
        }
    }

    private var trailingActionForegroundColor: Color {
        if viewModel.isRecording { return .white }
        return isDarkMode ? Color.sendButtonForegroundDark : Color.sendButtonForegroundLight
    }

    private var trailingActionBackgroundColor: Color {
        if viewModel.isRecording { return .red }
        return isDarkMode ? Color.sendButtonBackgroundDark : Color.sendButtonBackgroundLight
    }

    /// Icon content shared by both input layouts' trailing action button.
    @ViewBuilder
    private var trailingActionIcon: some View {
        if trailingAction == .voice && viewModel.isTranscribing {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: trailingActionForegroundColor))
                .scaleEffect(0.8)
        } else {
            Image(systemName: trailingActionIconName)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    // Attachment picker state


    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingPickerAction: PickerAction?
    @State private var showCameraPermissionAlert = false

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
            .onChange(of: textHeight) { _, newHeight in
                guard let isInputExpanded else { return }
                let expanded = newHeight > Layout.minimumHeight + 1
                if isInputExpanded.wrappedValue != expanded {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isInputExpanded.wrappedValue = expanded
                    }
                }
            }
            .alert("Microphone Access Required", isPresented: $viewModel.showMicrophonePermissionAlert) {
                Button("Open Settings") {
                    openSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To use voice input, please enable microphone access in Settings.")
            }
            .alert("Camera Access Required", isPresented: $showCameraPermissionAlert) {
                Button("Open Settings") {
                    openSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To take photos, please enable camera access in Settings.")
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
            .sheet(isPresented: $viewModel.showDocumentPicker) {
                DocumentPickerView { url, fileName in
                    viewModel.addDocumentAttachment(url: url, fileName: fileName)
                }
            }
            .sheet(isPresented: $viewModel.showPhotoPicker, onDismiss: processSelectedPhotos) {
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
                                viewModel.showPhotoPicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $viewModel.showCamera) {
                CameraPickerView { image in
                    if let data = image.jpegData(compressionQuality: CGFloat(Constants.Attachments.imageCompressionQuality)) {
                        viewModel.addImageAttachment(data: data, fileName: "Camera Photo.jpg")
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $viewModel.showAddSheet, onDismiss: {
                guard let action = pendingPickerAction else { return }
                pendingPickerAction = nil
                switch action {
                case .camera: requestCameraAccess()
                case .photos: viewModel.showPhotoPicker = true
                case .files: viewModel.showDocumentPicker = true
                }
            }) {
                AddToSheetView(
                    viewModel: viewModel,
                    isDarkMode: isDarkMode,
                    contextUsage: showContextIndicator ? contextUsage : nil,
                    onCamera: {
                        pendingPickerAction = .camera
                        viewModel.showAddSheet = false
                    },
                    onPhotos: {
                        pendingPickerAction = .photos
                        viewModel.showAddSheet = false
                    },
                    onFiles: {
                        pendingPickerAction = .files
                        viewModel.showAddSheet = false
                    }
                )
                .environmentObject(authManager)
                .presentationDetents([.height(showContextIndicator ? 324 : 280)])
                .presentationBackground(Color.sheetBackground(isDarkMode: isDarkMode))
            }
            .sheet(isPresented: $viewModel.showRateLimitPaywall) {
                GatedPaywallView {
                    viewModel.showRateLimitPaywall = false
                }
                    .onDisappear {
                        Task {
                            await authManager.fetchSubscriptionStatus()
                        }
                    }
            }
            .sheet(isPresented: $viewModel.showModelSelectorSheet) {
                ModelSelectorSheetView(viewModel: viewModel, isDarkMode: isDarkMode)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Color.sheetBackground(isDarkMode: isDarkMode))
            }
    }

    /// Small label shown above the input when remaining free requests are low
    @ViewBuilder
    private var rateLimitLabel: some View {
        if let rl = viewModel.rateLimit, rl.kind == .hourly {
            Text("Hourly limit reached")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.15))
                )
                .transition(.opacity)
        } else if let rl = viewModel.rateLimit, rl.remaining <= Constants.RateLimit.warningThreshold {
            let isOutOfRequests = rl.remaining <= 0
            Text(isOutOfRequests
                 ? "No requests left"
                 : "\(rl.remaining) request\(rl.remaining == 1 ? "" : "s") left")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOutOfRequests ? .orange : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isOutOfRequests
                              ? Color.orange.opacity(0.15)
                              : Color.secondary.opacity(0.12))
                )
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: rl.remaining)
                .onTapGesture {
                    if isOutOfRequests {
                        viewModel.showRateLimitPaywall = true
                    }
                }
                .accessibilityAddTraits(isOutOfRequests ? .isButton : [])
                .accessibilityHint(isOutOfRequests ? "Opens upgrade options" : "")
                .accessibilityAction {
                    if isOutOfRequests {
                        viewModel.showRateLimitPaywall = true
                    }
                }
        }
    }

    /// The indicator is hidden on a blank chat, matching the webapp's
    /// welcome screen behavior.
    private var showContextIndicator: Bool {
        !(viewModel.currentChat?.messages.isEmpty ?? true)
    }

    /// Estimated context usage for the conversation: non-archived messages
    /// plus the draft input and pending attachments, against the current
    /// model's token budget. Mirrors the webapp's calculation.
    private var contextUsage: ContextUsage {
        let limitTokens = TokenEstimation.contextTokenBudget(viewModel.currentModel.contextWindow)
        var usedTokens = TokenEstimation.estimateTokenCount(messageText)

        let messages = viewModel.messages
        let startIndex = TokenEstimation.findContextStartIndex(messages: messages, budgetTokens: limitTokens)
        for i in startIndex..<messages.count {
            usedTokens += TokenEstimation.estimateMessageTokens(messages[i])
        }

        for attachment in viewModel.pendingAttachments {
            usedTokens += TokenEstimation.estimateTokenCount(attachment.textContent)
            usedTokens += TokenEstimation.estimateTokenCount(attachment.description)
        }

        return ContextUsage(
            percentage: Double(usedTokens) / Double(limitTokens) * 100,
            usedTokens: usedTokens,
            limitTokens: limitTokens
        )
    }

    /// When the latest assistant message ends in an input-surface
    /// GenUI tool call, the chat input is replaced by the widget.
    private var pendingInputToolCall: PendingInputToolCall? {
        viewModel.currentChat?.pendingInputToolCall()
    }

    @ViewBuilder
    private var inputContent: some View {
        if let pending = pendingInputToolCall {
            genUIInputContainer(pending: pending)
        } else {
            standardInputContent
        }
    }

    @ViewBuilder
    private func genUIInputContainer(pending: PendingInputToolCall) -> some View {
        VStack(spacing: 8) {
            rateLimitLabel

            GenUIInputAreaView(
                pending: pending,
                isDarkMode: isDarkMode,
                onResolve: { toolCallId, resultText, resultData in
                    viewModel.resolveGenUIToolCall(
                        toolCallId: toolCallId,
                        resultText: resultText,
                        resultData: resultData
                    )
                },
                onCancel: nil
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 10)
        .padding(.bottom, max(inputBottomPadding, 12))
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(.thickMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(GenUIStyle.borderColor(isDarkMode))
        }
    }

    /// Shared between the iOS 26 and pre-26 input layouts so the editor's
    /// growing list of paste/send hooks stays defined in one place.
    private var messageTextEditor: some View {
        CustomTextEditor(text: $messageText,
                         textHeight: $textHeight,
                         placeholderText: viewModel.currentChat?.messages.isEmpty ?? true ? "What's on your mind?" : "Message",
                         shouldFocusInput: viewModel.shouldFocusInput,
                         handle: editorHandle,
                         allowsImagePaste: viewModel.currentModel.isMultimodal,
                         onFocusHandled: { viewModel.shouldFocusInput = false },
                         onSendMessage: { text in viewModel.sendMessage(text: text) },
                         onPasteImage: { data, fileName in viewModel.addImageAttachment(data: data, fileName: fileName) },
                         onPasteFile: { url, fileName in viewModel.addDocumentAttachment(url: url, fileName: fileName) },
                         onPasteFileError: { message in viewModel.attachmentError = message })
            .frame(height: textHeight)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var standardInputContent: some View {
        if #available(iOS 26, *) {
            // iOS 26+ with liquid glass effect
            VStack(spacing: 4) {
                rateLimitLabel

                // Host both interactive glass effects (the input container and
                // the send button) in one container so their gravity-well anchor
                // views attach here instead of directly under the hosting
                // controller's view, which UIKit warns against for hosted cells.
                GlassEffectContainer {
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
                messageTextEditor

                // Bottom row with action buttons
                HStack {
                    attachButton

                    modelSelectorButton

                    if viewModel.currentModel.isReasoningModel {
                        ReasoningEffortSelector(
                            supportsEffort: viewModel.currentModel.supportsReasoningEffort,
                            supportsToggle: viewModel.currentModel.supportsThinkingToggle,
                            reasoningEffort: $viewModel.reasoningEffort,
                            thinkingEnabled: $viewModel.thinkingEnabled
                        )
                        .padding(.leading, 4)
                    }

                    Spacer()

                    Button(action: handleTrailingActionTap) {
                        trailingActionIcon
                            .frame(width: 24, height: 24)
                            .foregroundColor(trailingActionForegroundColor)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .clipShape(.circle)
                    .tint(trailingActionBackgroundColor)
                    .scaleEffect(reduceMotion || !isPulsing ? 1.0 : 1.1)
                    .animation(
                        reduceMotion ? nil : (isPulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .easeInOut(duration: 0.2)),
                        value: isPulsing
                    )
                    .onChange(of: viewModel.isRecording) { _, isRecording in
                        isPulsing = isRecording
                    }
                    .disabled(isTrailingActionDisabled)
                    .accessibilityLabel(trailingActionAccessibilityLabel)
                    .accessibilityValue(viewModel.isTranscribing ? "Transcribing" : "")
                    .padding(.trailing, 8)
                }
                .padding(.vertical, 8)
            }
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
            }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, inputBottomPadding)
        } else {
            // Older iOS with material effect
            VStack(spacing: 4) {
                rateLimitLabel

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
                messageTextEditor

                // Bottom row with action buttons
                HStack {
                    attachButton

                    modelSelectorButton

                    if viewModel.currentModel.isReasoningModel {
                        ReasoningEffortSelector(
                            supportsEffort: viewModel.currentModel.supportsReasoningEffort,
                            supportsToggle: viewModel.currentModel.supportsThinkingToggle,
                            reasoningEffort: $viewModel.reasoningEffort,
                            thinkingEnabled: $viewModel.thinkingEnabled
                        )
                        .padding(.leading, 4)
                    }

                    Spacer()

                    Button(action: handleTrailingActionTap) {
                        ZStack {
                            Circle()
                                .fill(trailingActionBackgroundColor)
                                .frame(width: 32, height: 32)

                            trailingActionIcon
                                .foregroundColor(trailingActionForegroundColor)
                        }
                    }
                    .scaleEffect(reduceMotion || !isPulsing ? 1.0 : 1.1)
                    .animation(
                        reduceMotion ? nil : (isPulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .easeInOut(duration: 0.2)),
                        value: isPulsing
                    )
                    .onChange(of: viewModel.isRecording) { _, isRecording in
                        isPulsing = isRecording
                    }
                    .disabled(isTrailingActionDisabled)
                    .accessibilityLabel(trailingActionAccessibilityLabel)
                    .accessibilityValue(viewModel.isTranscribing ? "Transcribing" : "")
                    .accessibleHitTarget()
                    .padding(.trailing, 8)
                }
                .padding(.vertical, 8)
            }
            .background {
                RoundedRectangle(cornerRadius: 26)
                    .fill(.thickMaterial)
            }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, inputBottomPadding)
        }
    }

    private var inputBottomPadding: CGFloat {
        if isKeyboardVisible {
            return 12
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return Constants.UI.iPadInputBottomPadding
        }
        return 0
    }

    @ViewBuilder
    private var attachButton: some View {
        Button {
            viewModel.showAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
        }
        .disabled(viewModel.isProcessingAttachment)
        .accessibilityLabel("Add attachment")
        .accessibleHitTarget()
        .padding(.leading, 8)
    }

    @ViewBuilder
    private var modelSelectorButton: some View {
        Button {
            viewModel.showModelSelectorSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.currentModel.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .disabled(viewModel.isLoading)
        .accessibilityLabel("Model")
        .accessibilityValue(viewModel.currentModel.displayName)
        .accessibilityHint("Changes the AI model")
        .padding(.leading, 4)
    }

    private func handleTrailingActionTap() {
        if trailingAction == .voice {
            handleAudioButtonTap()
        } else {
            sendOrCancelMessage()
        }
    }

    private func sendOrCancelMessage() {
        if showStopAction {
            viewModel.cancelGeneration()
        } else if hasSubmittableContent {
            // Only clear the input when the message was actually sent or
            // queued; a rejected draft (full queue, rate limit) stays put.
            if viewModel.sendMessage(text: messageText) {
                messageText = ""
                editorHandle.clearDraft()
                textHeight = Layout.defaultHeight
            }
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

    private func requestCameraAccess() {
        switch cameraPermissionAction(for: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .presentCamera:
            viewModel.showCamera = true
        case .requestAccess:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        viewModel.showCamera = true
                    } else {
                        showCameraPermissionAlert = true
                    }
                }
            }
        case .showSettingsAlert:
            showCameraPermissionAlert = true
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Bottom sheet presented from the "+" button with attachment options and web search toggle
struct AddToSheetView: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var settings = SettingsManager.shared
    let isDarkMode: Bool
    let contextUsage: ContextUsage?
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    @Environment(\.dismiss) private var dismiss

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

                Text("Chat Features")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)

                if settings.webSearchAvailable {
                    Toggle(isOn: Binding(
                        get: { viewModel.isWebSearchEnabled },
                        set: { viewModel.setWebSearchEnabled($0) }
                    )) {
                        Label("Web Search", systemImage: "globe")
                    }
                    .tint(.green)
                    .padding(.horizontal, 20)
                }

                if let contextUsage {
                    HStack {
                        Label("Context Used", systemImage: "text.alignleft")
                        Spacer()
                        ContextUsageIndicator(usage: contextUsage)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.sheetBackground(isDarkMode: isDarkMode).ignoresSafeArea())
            .navigationTitle("Add to Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close")
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

/// Bottom sheet for selecting a model from the input bar
struct ModelSelectorSheetView: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    let isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss

    private var availableModels: [ModelType] {
        AppConfig.shared.selectableModels
    }

    /// Auto entries have no asset icon; show a routing glyph instead.
    @ViewBuilder
    private func modelIcon(for model: ModelType) -> some View {
        if model.isAuto {
            Image(systemName: "shuffle")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            Image(model.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        }
    }

    var body: some View {
        NavigationStack {
            List(availableModels) { model in
                let isSelected = viewModel.currentModel.id == model.id
                Button {
                    viewModel.changeModel(to: model)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        modelIcon(for: model)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text(model.description)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

/// Lets the owning view reach into the editor imperatively. Clearing the
/// draft through the coordinator keeps the UITextView, the binding, and the
/// keyboard focus consistent in one synchronous step, instead of relying on
/// a render pass to propagate an emptied binding back into UIKit.
final class CustomTextEditorHandle {
    fileprivate weak var coordinator: CustomTextEditor.Coordinator?

    func clearDraft() {
        coordinator?.clearDraft()
    }
}

/// Custom UIViewRepresentable for a properly managed text editor
struct CustomTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var textHeight: CGFloat
    var placeholderText: String
    var shouldFocusInput: Bool
    var handle: CustomTextEditorHandle? = nil
    var allowsImagePaste: Bool = false
    var onFocusHandled: () -> Void
    /// Returns whether the message was accepted, so the editor only clears
    /// itself when the draft was actually sent or queued.
    var onSendMessage: (String) -> Bool
    var onPasteImage: ((Data, String) -> Void)? = nil
    var onPasteFile: ((URL, String) -> Void)? = nil
    var onPasteFileError: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = PastingTextView()
        textView.allowsImagePaste = allowsImagePaste
        textView.onPasteImage = onPasteImage
        textView.onPasteFile = onPasteFile
        textView.onPasteFileError = onPasteFileError
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
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityLabel = "Message"

        context.coordinator.textView = textView
        handle?.coordinator = context.coordinator

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

        context.coordinator.refreshAccessibility(textView)
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        handle?.coordinator = context.coordinator
        if let pastingView = uiView as? PastingTextView {
            pastingView.allowsImagePaste = allowsImagePaste
            pastingView.onPasteImage = onPasteImage
            pastingView.onPasteFile = onPasteFile
            pastingView.onPasteFileError = onPasteFileError
        }
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

        // A clear can race a render whose state snapshot predates it: the
        // view model publishes on every streaming token, so such a pass can
        // still read the old draft from the binding after `clearDraft` ran
        // and would write it straight back into the emptied editor. Treat
        // exactly that value as empty until a fresher one arrives.
        var text = self.text
        if let clearedDraft = context.coordinator.clearedDraft {
            if text == clearedDraft {
                text = ""
            } else {
                context.coordinator.clearedDraft = nil
            }
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
        context.coordinator.refreshAccessibility(uiView)

        let newHeight = context.coordinator.measuredHeight(for: uiView)

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
        weak var textView: UITextView?
        /// The draft text at the moment `clearDraft` ran. While streaming, the
        /// view model publishes on every token, so a render transaction whose
        /// state snapshot predates the send can reach `updateUIView` after the
        /// clear, still carrying the old draft in the binding. That value must
        /// be recognized and ignored or it gets written back into the emptied
        /// editor and then resynced into the binding, undoing the clear.
        var clearedDraft: String?
        private var lastMeasurement: (text: String, width: CGFloat, pointSize: CGFloat, height: CGFloat)?

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        /// Empties the draft in one synchronous step: the UITextView, the
        /// text binding, and the reported height all reset together, keeping
        /// focus (and the keyboard) exactly as they were. Without this, an
        /// emptied binding reaching `updateUIView` while the editor is still
        /// focused is indistinguishable from a stale binding and the draft
        /// text gets resynced right back into it.
        func clearDraft() {
            guard let textView else { return }
            clearedDraft = textView.text
            if isEditing {
                textView.text = ""
                textView.textColor = UIColor { traitCollection in
                    return traitCollection.userInterfaceStyle == .dark ? .white : .black
                }
            } else {
                textView.text = parent.placeholderText
                textView.textColor = .lightGray
            }
            parent.text = ""
            parent.textHeight = MessageInputView.Layout.defaultHeight
            refreshAccessibility(textView)
        }

        /// Returns the editor height for the current draft, avoiding repeated
        /// full-document TextKit layout: results are cached per text/width/font
        /// so keyboard-driven SwiftUI updates don't re-measure an unchanged
        /// draft, and drafts that trivially exceed the height cap skip
        /// measurement entirely.
        func measuredHeight(for textView: UITextView) -> CGFloat {
            let text = textView.text ?? ""
            let width = textView.frame.width
            let pointSize = textView.font?.pointSize ?? 0

            if let last = lastMeasurement,
               last.text == text, last.width == width, last.pointSize == pointSize {
                return last.height
            }

            let height: CGFloat
            if Self.exceedsMaximumHeight(text) {
                height = MessageInputView.Layout.maximumHeight
            } else {
                let size = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                height = min(MessageInputView.Layout.maximumHeight, max(MessageInputView.Layout.minimumHeight, size.height))
            }

            lastMeasurement = (text, width, pointSize, height)
            return height
        }

        private static func exceedsMaximumHeight(_ text: String) -> Bool {
            if text.count >= MessageInputView.Layout.overflowCharacterCount { return true }
            var newlines = 0
            for character in text where character == "\n" {
                newlines += 1
                if newlines >= MessageInputView.Layout.overflowNewlineCount { return true }
            }
            return false
        }

        /// Keeps VoiceOver from reading the gray placeholder as if it were
        /// entered text: the field always reports a stable "Message" label and
        /// only exposes a value once real text has been typed.
        func refreshAccessibility(_ textView: UITextView) {
            textView.accessibilityLabel = "Message"
            let isShowingPlaceholder = textView.textColor == .lightGray
            textView.accessibilityValue = isShowingPlaceholder ? "" : textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Check if Enter key was pressed (without Shift)
            if text == "\n" {
                // Check if this is running on Mac (iOS app on Mac)
                let isMac = ProcessInfo.processInfo.isiOSAppOnMac
                
                if isMac {
                    let currentText = textView.text ?? ""
                    let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Sending while a response is streaming queues the message
                    // and keeps focus so the next draft can be typed; a direct
                    // send dismisses the keyboard itself, after which the
                    // clear falls back to showing the placeholder.
                    if !trimmedText.isEmpty && parent.onSendMessage(trimmedText) {
                        clearDraft()
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
                let newHeight = measuredHeight(for: textView)
                
                if parent.textHeight != newHeight {
                    parent.textHeight = newHeight
                }
            }
            refreshAccessibility(textView)
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
            refreshAccessibility(textView)
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            // Add placeholder if needed when editing ends
            if textView.text.isEmpty {
                textView.text = parent.placeholderText
                textView.textColor = .lightGray
            }
            refreshAccessibility(textView)
        }
    }
}

/// UITextView that accepts images and file URLs from the pasteboard in
/// addition to plain text, turning them into attachments.
final class PastingTextView: UITextView {
    var allowsImagePaste = false
    var onPasteImage: ((Data, String) -> Void)?
    var onPasteFile: ((URL, String) -> Void)?
    var onPasteFileError: ((String) -> Void)?

    /// File URLs win over any string representation on the pasteboard:
    /// copying a file (e.g. from the Files app) often includes its name as
    /// plain text, and pasting that name instead of the file would be wrong.
    private var pasteboardFileURLs: [URL] {
        UIPasteboard.general.urls?.filter { $0.isFileURL } ?? []
    }

    /// UIKit probes `canPerformAction` many times while assembling the edit
    /// menu, and each `hasImages`/`urls` read is a synchronous XPC round trip
    /// to the pasteboard service. Cache the answers per pasteboard
    /// generation so only the first probe pays that cost.
    private var cachedPasteboardState: (changeCount: Int, hasImages: Bool, hasFileURLs: Bool)?

    private func pasteboardState() -> (hasImages: Bool, hasFileURLs: Bool) {
        let changeCount = UIPasteboard.general.changeCount
        if let cached = cachedPasteboardState, cached.changeCount == changeCount {
            return (cached.hasImages, cached.hasFileURLs)
        }
        let state = (
            changeCount: changeCount,
            hasImages: UIPasteboard.general.hasImages,
            hasFileURLs: !pasteboardFileURLs.isEmpty
        )
        cachedPasteboardState = state
        return (state.hasImages, state.hasFileURLs)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            if allowsImagePaste && onPasteImage != nil && pasteboardState().hasImages {
                return true
            }
            if onPasteFile != nil && pasteboardState().hasFileURLs {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general

        if allowsImagePaste, pasteboard.hasImages,
           let onPasteImage, let images = pasteboard.images, !images.isEmpty {
            for (index, image) in images.enumerated() {
                guard let data = image.jpegData(
                    compressionQuality: CGFloat(Constants.Attachments.imageCompressionQuality)
                ) else { continue }
                let fileName = images.count > 1 ? "Pasted Image \(index + 1).jpg" : "Pasted Image.jpg"
                onPasteImage(data, fileName)
            }
            return
        }

        if let onPasteFile {
            let fileURLs = pasteboardFileURLs
            if !fileURLs.isEmpty {
                for url in fileURLs {
                    importPastedFile(url: url, onPasteFile: onPasteFile)
                }
                return
            }
        }

        super.paste(sender)
    }

    /// Copies a pasted file into the app's temp directory so the attachment
    /// pipeline can read it after the pasteboard's access window closes.
    /// Oversized files are rejected up front: the pipeline would refuse them
    /// anyway, and copying or reading them first would waste disk and memory.
    private func importPastedFile(url: URL, onPasteFile: (URL, String) -> Void) {
        let fileName = url.lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + fileName)
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) > Constants.Attachments.maxFileSizeBytes {
            let message = DocumentProcessingService.ProcessingError
                .fileTooLarge(Int64(fileSize)).errorDescription
            onPasteFileError?(message ?? "File is too large.")
            return
        }

        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            onPasteFile(tempURL, fileName)
        } catch {
            onPasteFileError?("Couldn't read the pasted file. Try attaching it with the + button instead.")
        }
    }
} 
