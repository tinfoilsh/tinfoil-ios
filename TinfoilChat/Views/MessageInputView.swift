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

func shouldShowMessageStopAction(
    isStreaming: Bool,
    hasActiveRecovery: Bool,
    hasSubmittableContent: Bool,
    isMessageQueueFull: Bool
) -> Bool {
    hasActiveRecovery
        || (isStreaming && (!hasSubmittableContent || isMessageQueueFull))
}

func hasNonWhitespaceContent(_ text: String) -> Bool {
    text.contains { !$0.isWhitespace }
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
    @ObservedObject private var recoveryPhaseTracker = ChatRecoveryPhaseTracker.shared
    @State private var textHeight: CGFloat = Layout.defaultHeight
    @State private var messageTextHasNonWhitespace = false
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

    // Tracks a press-and-hold recording so a release is what stops it and
    // other action paths don't re-toggle the microphone.
    @State private var isHoldToRecordActive = false
    @State private var isFloatingRecordingBubbleVisible = false

    // The in-flight recorder startup for a hold, awaited on release so a
    // fast release can't try to stop a recording that hasn't started yet
    // and leave it running.
    @State private var holdToRecordStartTask: Task<Void, Never>?

    /// The recording look (red stop button) keys off the hold itself as well
    /// as the recorder, so feedback is instant instead of waiting for the
    /// audio session to spin up.
    private var showsRecordingState: Bool {
        viewModel.isRecording || isHoldToRecordActive
    }

    // Clears the editor's UITextView imperatively at send time, so the draft
    // disappears even while the editor keeps focus (queued sends don't
    // dismiss the keyboard) without depending on render timing.
    @State private var editorHandle = CustomTextEditorHandle()
    @State private var preservedMessageDraft: String?
    @State private var activeMessageEditSessionID: UUID?
    @State private var activeMessageEditChatID: String?

    private var isEditingMessage: Bool {
        viewModel.messageEditSession != nil
    }

    private var canSaveMessageEdit: Bool {
        messageTextHasNonWhitespace
            && !viewModel.isLoading
            && viewModel.canUseCurrentChatActions
            && !viewModel.hasPendingResponseRecovery
            && viewModel.pendingAttachments.isEmpty
    }

    /// A draft that can actually be sent or queued right now: attachments
    /// all processed, plus either non-whitespace text or at least one
    /// attachment. Matches `sendMessage`'s own guards so the button never
    /// offers a send that would be rejected.
    private var hasSubmittableContent: Bool {
        guard attachmentsAreReadyToSend(viewModel.pendingAttachments) else { return false }
        return messageTextHasNonWhitespace
            || !viewModel.pendingAttachments.isEmpty
    }

    /// While a response is streaming, the button stays a send button only
    /// while a sendable draft can actually be queued; with nothing
    /// submittable, or the queue already full, it reverts to a stop button
    /// so the stream can always be cancelled. Mirrors the webapp.
    private var showStopAction: Bool {
        shouldShowMessageStopAction(
            isStreaming: viewModel.isLoading,
            hasActiveRecovery: viewModel.activeRecoveryEnvelope(
                trackedBy: recoveryPhaseTracker
            ) != nil,
            hasSubmittableContent: hasSubmittableContent,
            isMessageQueueFull: viewModel.isMessageQueueFull
        )
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
        if showAudioButton && showsRecordingState {
            return .voice
        }
        if showStopAction { return .stop }
        if showAudioButton && viewModel.isTranscribing {
            return .voice
        }
        if showAudioButton,
           !messageTextHasNonWhitespace,
           viewModel.pendingAttachments.isEmpty {
            return .voice
        }
        return .send
    }

    private var trailingActionIconName: String {
        switch trailingAction {
        case .voice: return showsRecordingState ? "stop.fill" : "waveform"
        case .send: return "arrow.up"
        case .stop: return "stop.fill"
        }
    }

    private var trailingActionAccessibilityLabel: String {
        switch trailingAction {
        case .voice: return showsRecordingState ? "Stop recording" : "Voice input"
        case .send: return "Send message"
        case .stop: return "Stop generating"
        }
    }

    /// The send action greys out while a draft can't be dispatched because
    /// an attachment is still processing or the previous response is being
    /// recovered; voice greys out while a recording is being transcribed.
    private var isTrailingActionDisabled: Bool {
        guard viewModel.canUseCurrentChatActions else { return true }
        switch trailingAction {
        case .voice: return viewModel.isTranscribing
        case .send:
            return viewModel.hasPendingResponseRecovery
                || !attachmentsAreReadyToSend(viewModel.pendingAttachments)
        case .stop: return false
        }
    }

    private var trailingActionForegroundColor: Color {
        if showsRecordingState { return .white }
        return isDarkMode ? Color.sendButtonForegroundDark : Color.sendButtonForegroundLight
    }

    private var trailingActionBackgroundColor: Color {
        if showsRecordingState { return .red }
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
            .onAppear {
                messageTextHasNonWhitespace = hasNonWhitespaceContent(messageText)
                handleMessageEditSessionChange(viewModel.messageEditSession)
            }
            .onChange(of: messageText) { _, newValue in
                messageTextHasNonWhitespace = hasNonWhitespaceContent(newValue)
            }
            .onChange(of: viewModel.messageEditSession) { _, newSession in
                handleMessageEditSessionChange(newSession)
            }
            .onChange(of: viewModel.currentChat?.id) { _, newChatId in
                handleChatChange(newChatId)
            }
            .disabled(!viewModel.canUseCurrentChatActions)
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
                DocumentPickerView(
                    onDocumentPicked: { handle in
                        viewModel.addDocumentAttachment(handle: handle)
                    },
                    onError: { error in
                        viewModel.attachmentError = error.localizedDescription
                    }
                )
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
                .presentationDetents([
                    .height(
                        showContextIndicator
                            ? Constants.AddToChatSheet.heightWithContext
                            : Constants.AddToChatSheet.height
                    )
                ])
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
        let limitTokens = TokenEstimation.contextTokenBudget(viewModel.currentModel.contextWindowTokens)
        let reasoningHistoryPolicy = AppConfig.shared.reasoningHistoryPolicy(for: viewModel.currentModel)
        var usedTokens = TokenEstimation.estimateTokenCount(messageText)

        let messages = viewModel.messages
        let startIndex = TokenEstimation.findContextStartIndex(
            messages: messages,
            budgetTokens: limitTokens,
            reasoningHistoryPolicy: reasoningHistoryPolicy
        )
        for i in startIndex..<messages.count {
            usedTokens += TokenEstimation.estimateMessageTokens(
                messages[i],
                reasoningHistoryPolicy: reasoningHistoryPolicy
            )
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
        if isEditingMessage {
            standardInputContent
        } else if let pending = pendingInputToolCall {
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
                         allowsImagePaste: !isEditingMessage && viewModel.currentModel.isMultimodal,
                         rejectsAttachmentPaste: isEditingMessage,
                         onFocusHandled: { viewModel.shouldFocusInput = false },
                         onSendMessage: submitEditorText,
                         onPasteImage: isEditingMessage ? nil : { data, fileName in viewModel.addImageAttachment(data: data, fileName: fileName) },
                         onPasteFile: isEditingMessage ? nil : { handle in viewModel.addDocumentAttachment(handle: handle) },
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

                if isEditingMessage {
                    messageEditHeader
                }

                // Text input area
                messageTextEditor

                // Bottom row with action buttons
                HStack {
                    if isEditingMessage {
                        messageEditActions
                    } else {
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

                        trailingActionButton
                    }
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

                if isEditingMessage {
                    messageEditHeader
                }

                // Text input area
                messageTextEditor

                // Bottom row with action buttons
                HStack {
                    if isEditingMessage {
                        messageEditActions
                    } else {
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

                        trailingActionButton
                    }
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

    private var messageEditHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Editing this message will restart the conversation from this point.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(action: cancelMessageEdit) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibleHitTarget()
                .accessibilityLabel("Cancel edit")
                .accessibilityHint("Restores your previous draft")
            }

            if !viewModel.pendingAttachments.isEmpty {
                Text("Remove pending attachments before saving this edit.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var messageEditActions: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Cancel", action: cancelMessageEdit)
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel edit")
                .accessibilityHint("Restores your previous draft")

            Button("Save", action: saveMessageEdit)
                .fontWeight(.semibold)
                .buttonStyle(.plain)
                .disabled(!canSaveMessageEdit)
                .accessibilityLabel("Save edit")
                .accessibilityHint("Replaces the message and regenerates later responses")
        }
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity)
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
        .accessibilityLabel("Add to chat")
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

    /// UIKit owns the complete touch lifecycle here. Its long-press
    /// recognizer and floating window-level bubble avoid SwiftUI's input
    /// layout, clipping, and coordinate-space changes during the gesture.
    @ViewBuilder
    private var trailingActionButton: some View {
        ZStack {
            styledTrailingActionContent
                .opacity(isFloatingRecordingBubbleVisible ? 0 : 1)
                .accessibilityHidden(true)

            HoldToRecordControl(
                isEnabled: !isTrailingActionDisabled,
                allowsHoldToRecord: allowsHoldToRecord,
                reduceMotion: reduceMotion,
                accessibilityLabel: trailingActionAccessibilityLabel,
                accessibilityValue: viewModel.isTranscribing ? "Transcribing" : "",
                onTap: handleTrailingActionTap,
                onHoldBegan: beginHoldToRecord,
                onHoldEnded: endHoldToRecord,
                onBubbleVisibilityChanged: { isFloatingRecordingBubbleVisible = $0 }
            )
            .frame(
                width: Constants.Audio.recordingButtonHitTargetSize,
                height: Constants.Audio.recordingButtonHitTargetSize
            )
        }
        .frame(
            width: Constants.Audio.recordingButtonHitTargetSize,
            height: Constants.Audio.recordingButtonHitTargetSize
        )
        .opacity(isTrailingActionDisabled ? 0.6 : 1.0)
        .allowsHitTesting(!isTrailingActionDisabled)
        .padding(.trailing, 8)
    }

    private var allowsHoldToRecord: Bool {
        showAudioButton
            && trailingAction != .stop
            && !viewModel.isRecording
            && !viewModel.isTranscribing
    }

    @ViewBuilder
    private var styledTrailingActionContent: some View {
        if #available(iOS 26, *) {
            trailingActionIcon
                .frame(width: 24, height: 24)
                .foregroundColor(trailingActionForegroundColor)
                .padding(4)
                .glassEffect(.regular.tint(trailingActionBackgroundColor).interactive(), in: .circle)
        } else {
            ZStack {
                Circle()
                    .fill(trailingActionBackgroundColor)
                    .frame(width: 32, height: 32)

                trailingActionIcon
                    .foregroundColor(trailingActionForegroundColor)
            }
        }
    }

    private func endHoldToRecord() {
        guard isHoldToRecordActive else { return }
        isHoldToRecordActive = false
        let startTask = holdToRecordStartTask
        holdToRecordStartTask = nil
        Task {
            // The recorder starts asynchronously (permission prompt,
            // session setup), so wait for the startup to finish before
            // stopping; otherwise a fast release finds nothing to stop
            // and the recording outlives the hold.
            await startTask?.value
            await stopRecordingAndInsertTranscription()
        }
    }

    /// Holding records in both the microphone and send roles, so a drafted
    /// message can still be extended by voice; the transcription appends to
    /// the text. Only the stop role is excluded, since holding stop must
    /// keep meaning stop.
    private func beginHoldToRecord() -> Bool {
        guard showAudioButton,
              trailingAction != .stop,
              !viewModel.isRecording,
              !viewModel.isTranscribing else { return false }
        isHoldToRecordActive = true
        holdToRecordStartTask = Task {
            await viewModel.startAudioRecording()
        }
        return true
    }

    private func handleTrailingActionTap() {
        if isHoldToRecordActive { return }
        if trailingAction == .voice {
            handleAudioButtonTap()
        } else {
            sendOrCancelMessage()
        }
    }

    private func handleMessageEditSessionChange(_ session: MessageEditSession?) {
        guard let session else {
            guard activeMessageEditSessionID != nil else { return }
            let restoredDraft = activeMessageEditChatID == viewModel.currentChat?.id
                ? preservedMessageDraft ?? ""
                : ""
            activeMessageEditSessionID = nil
            activeMessageEditChatID = nil
            preservedMessageDraft = nil
            editorHandle.replaceDraft(restoredDraft)
            messageText = restoredDraft
            return
        }
        guard activeMessageEditSessionID != session.id else { return }
        if activeMessageEditSessionID == nil {
            preservedMessageDraft = messageText
        }
        activeMessageEditSessionID = session.id
        activeMessageEditChatID = session.chatId
        editorHandle.replaceDraft(session.originalContent)
        messageText = session.originalContent
        viewModel.shouldFocusInput = true
    }

    private func handleChatChange(_ chatId: String?) {
        guard activeMessageEditSessionID != nil,
              activeMessageEditChatID != chatId else { return }
        activeMessageEditSessionID = nil
        activeMessageEditChatID = nil
        preservedMessageDraft = nil
        editorHandle.replaceDraft("")
        messageText = ""
        textHeight = Layout.defaultHeight
        viewModel.cancelMessageEdit()
    }

    private func cancelMessageEdit() {
        let restoredDraft = activeMessageEditChatID == viewModel.currentChat?.id
            ? preservedMessageDraft ?? ""
            : ""
        activeMessageEditSessionID = nil
        activeMessageEditChatID = nil
        preservedMessageDraft = nil
        editorHandle.replaceDraft(restoredDraft)
        messageText = restoredDraft
        viewModel.cancelMessageEdit()
    }

    private func saveMessageEdit() {
        guard submitEditorText(messageText) else { return }
        editorHandle.clearDraft()
        textHeight = Layout.defaultHeight
    }

    private func submitEditorText(_ text: String) -> Bool {
        guard isEditingMessage else {
            return viewModel.sendMessage(text: text)
        }
        guard viewModel.saveMessageEdit(newContent: text) else { return false }
        activeMessageEditSessionID = nil
        activeMessageEditChatID = nil
        preservedMessageDraft = nil
        messageText = ""
        return true
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
        if viewModel.isRecording {
            Task {
                await stopRecordingAndInsertTranscription()
            }
        } else {
            Task {
                await viewModel.startAudioRecording()
            }
        }
    }

    private func stopRecordingAndInsertTranscription() async {
        if let transcription = await viewModel.stopAudioRecordingAndTranscribe() {
            if !hasNonWhitespaceContent(messageText) {
                messageText = transcription
            } else {
                messageText += " " + transcription
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

private struct HoldToRecordControl: UIViewRepresentable {
    let isEnabled: Bool
    let allowsHoldToRecord: Bool
    let reduceMotion: Bool
    let accessibilityLabel: String
    let accessibilityValue: String
    let onTap: () -> Void
    let onHoldBegan: () -> Bool
    let onHoldEnded: () -> Void
    let onBubbleVisibilityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> HoldToRecordTouchView {
        let view = HoldToRecordTouchView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: HoldToRecordTouchView, context: Context) {
        context.coordinator.configure(
            isEnabled: isEnabled,
            allowsHoldToRecord: allowsHoldToRecord,
            reduceMotion: reduceMotion,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            onTap: onTap,
            onHoldBegan: onHoldBegan,
            onHoldEnded: onHoldEnded,
            onBubbleVisibilityChanged: onBubbleVisibilityChanged
        )
    }

    static func dismantleUIView(_ uiView: HoldToRecordTouchView, coordinator: Coordinator) {
        coordinator.cancelActiveInteraction()
    }

    final class Coordinator: NSObject {
        private weak var sourceView: HoldToRecordTouchView?
        private weak var sourceWindow: UIWindow?
        private var bubbleView: FloatingRecordingBubbleView?
        private var tapRecognizer: UITapGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?
        private var isEnabled = true
        private var allowsHoldToRecord = false
        private var reduceMotion = false
        private var isHoldActive = false
        private var isReturningBubble = false
        private var sourceCenterInWindow = CGPoint.zero
        private var holdStartLocationInWindow = CGPoint.zero
        private var onTap: () -> Void = {}
        private var onHoldBegan: () -> Bool = { false }
        private var onHoldEnded: () -> Void = {}
        private var onBubbleVisibilityChanged: (Bool) -> Void = { _ in }

        func attach(to view: HoldToRecordTouchView) {
            sourceView = view
            view.backgroundColor = .clear
            view.isOpaque = false
            view.isAccessibilityElement = true
            view.onAccessibilityActivate = { [weak self] in
                self?.activateTap() ?? false
            }

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = Constants.Audio.holdToRecordMinimumPressSeconds
            longPress.allowableMovement = .greatestFiniteMagnitude
            view.addGestureRecognizer(longPress)
            longPressRecognizer = longPress

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.require(toFail: longPress)
            view.addGestureRecognizer(tap)
            tapRecognizer = tap
        }

        func configure(
            isEnabled: Bool,
            allowsHoldToRecord: Bool,
            reduceMotion: Bool,
            accessibilityLabel: String,
            accessibilityValue: String,
            onTap: @escaping () -> Void,
            onHoldBegan: @escaping () -> Bool,
            onHoldEnded: @escaping () -> Void,
            onBubbleVisibilityChanged: @escaping (Bool) -> Void
        ) {
            self.isEnabled = isEnabled
            self.allowsHoldToRecord = allowsHoldToRecord
            self.reduceMotion = reduceMotion
            self.onTap = onTap
            self.onHoldBegan = onHoldBegan
            self.onHoldEnded = onHoldEnded
            self.onBubbleVisibilityChanged = onBubbleVisibilityChanged

            sourceView?.accessibilityLabel = accessibilityLabel
            sourceView?.accessibilityValue = accessibilityValue
            updateAccessibilityTraits()
            updateInteractionState()
        }

        @objc private func handleTap() {
            _ = activateTap()
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                beginHold(using: recognizer)
            case .changed:
                moveBubble(using: recognizer)
            case .ended, .cancelled, .failed:
                finishHold()
            default:
                break
            }
        }

        private func activateTap() -> Bool {
            guard isEnabled, !isReturningBubble, !isHoldActive else { return false }
            onTap()
            return true
        }

        private func beginHold(using recognizer: UILongPressGestureRecognizer) {
            guard isEnabled,
                  allowsHoldToRecord,
                  !isHoldActive,
                  !isReturningBubble,
                  let sourceView,
                  let window = sourceView.window,
                  onHoldBegan() else { return }

            isHoldActive = true
            sourceWindow = window
            sourceCenterInWindow = sourceView.convert(
                CGPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
                to: window
            )
            holdStartLocationInWindow = recognizer.location(in: window)

            let bubble = FloatingRecordingBubbleView(reduceMotion: reduceMotion)
            bubble.center = sourceCenterInWindow
            bubble.transform = CGAffineTransform(
                scaleX: Constants.Audio.recordingButtonScale,
                y: Constants.Audio.recordingButtonScale
            )
            window.addSubview(bubble)
            bubbleView = bubble
            onBubbleVisibilityChanged(true)
            bubble.startPulsing()
            updateInteractionState()
        }

        private func moveBubble(using recognizer: UILongPressGestureRecognizer) {
            guard isHoldActive, let sourceWindow, let bubbleView else { return }
            let location = recognizer.location(in: sourceWindow)
            bubbleView.center = CGPoint(
                x: sourceCenterInWindow.x + location.x - holdStartLocationInWindow.x,
                y: sourceCenterInWindow.y + location.y - holdStartLocationInWindow.y
            )
        }

        private func finishHold() {
            guard isHoldActive else { return }
            isHoldActive = false
            isReturningBubble = true
            onHoldEnded()
            updateInteractionState()

            guard let bubbleView else {
                completeBubbleReturn()
                return
            }

            bubbleView.stopPulsing()
            let animations = {
                bubbleView.center = self.sourceCenterInWindow
                bubbleView.transform = .identity
            }
            let completion: (Bool) -> Void = { [weak self] _ in
                self?.completeBubbleReturn()
            }

            if reduceMotion {
                animations()
                completion(true)
            } else {
                UIView.animate(
                    withDuration: Constants.Audio.recordingButtonReturnDuration,
                    delay: 0,
                    usingSpringWithDamping: Constants.Audio.recordingButtonReturnDamping,
                    initialSpringVelocity: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction],
                    animations: animations,
                    completion: completion
                )
            }
        }

        private func completeBubbleReturn() {
            bubbleView?.removeFromSuperview()
            bubbleView = nil
            sourceWindow = nil
            isReturningBubble = false
            onBubbleVisibilityChanged(false)
            updateInteractionState()
        }

        func cancelActiveInteraction() {
            if isHoldActive {
                isHoldActive = false
                onHoldEnded()
            }
            bubbleView?.removeFromSuperview()
            bubbleView = nil
            sourceWindow = nil
            isReturningBubble = false
            onBubbleVisibilityChanged(false)
        }

        private func updateInteractionState() {
            let acceptsInput = isEnabled && !isReturningBubble
            sourceView?.isUserInteractionEnabled = acceptsInput
            tapRecognizer?.isEnabled = acceptsInput
            longPressRecognizer?.isEnabled = acceptsInput && (allowsHoldToRecord || isHoldActive)
        }

        private func updateAccessibilityTraits() {
            var traits: UIAccessibilityTraits = [.button]
            if !isEnabled {
                traits.insert(.notEnabled)
            }
            sourceView?.accessibilityTraits = traits
        }
    }
}

private final class HoldToRecordTouchView: UIView {
    var onAccessibilityActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?() ?? false
    }
}

private final class FloatingRecordingBubbleView: UIView {
    private static let pulseAnimationKey = "recordingPulse"

    private let circleView = UIView()
    private let iconView = UIImageView()
    private let reduceMotion: Bool

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(
            frame: CGRect(
                origin: .zero,
                size: CGSize(
                    width: Constants.Audio.recordingButtonDiameter,
                    height: Constants.Audio.recordingButtonDiameter
                )
            )
        )
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        circleView.frame = bounds
        circleView.backgroundColor = .systemRed
        circleView.layer.cornerRadius = Constants.Audio.recordingButtonDiameter / 2
        addSubview(circleView)

        let configuration = UIImage.SymbolConfiguration(
            pointSize: Constants.Audio.recordingButtonIconPointSize,
            weight: .semibold
        )
        iconView.image = UIImage(systemName: "stop.fill", withConfiguration: configuration)
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.frame = circleView.bounds
        circleView.addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func startPulsing() {
        guard !reduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = Constants.Audio.recordingButtonPulseScale
        pulse.duration = Constants.Audio.recordingButtonPulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        circleView.layer.add(pulse, forKey: Self.pulseAnimationKey)
    }

    func stopPulsing() {
        circleView.layer.removeAnimation(forKey: Self.pulseAnimationKey)
    }
}

/// Bottom sheet presented from the "+" button with attachment options and chat features
struct AddToSheetView: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared
    let isDarkMode: Bool
    let contextUsage: ContextUsage?
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var selectedPrompt: PromptPreset? {
        profileManager.promptPreset(for: viewModel.currentChat?.promptPresetId)
    }

    private var promptDisplay: (name: String, icon: String) {
        if let selectedPrompt {
            return (selectedPrompt.name, selectedPrompt.iconName)
        }
        if viewModel.currentChat?.promptPresetId != nil {
            return ("Unavailable", "exclamationmark.triangle")
        }
        if profileManager.isUsingCustomPrompt || settings.isUsingCustomPrompt {
            return ("Custom Prompt", "square.and.pencil")
        }
        return ("Default", "text.quote")
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

                NavigationLink {
                    PromptLibraryView(
                        activePresetId: viewModel.currentChat?.promptPresetId,
                        onSelectPreset: { viewModel.setPromptPreset($0) }
                    )
                } label: {
                    HStack {
                        Label("Prompt", systemImage: promptDisplay.icon)
                        Spacer()
                        Text(promptDisplay.name)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 20)
                .accessibilityValue(promptDisplay.name)

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
    private var pendingDraftReplacement: String?

    fileprivate func attach(_ coordinator: CustomTextEditor.Coordinator) {
        self.coordinator = coordinator
        if let pendingDraftReplacement {
            self.pendingDraftReplacement = nil
            coordinator.replaceDraft(with: pendingDraftReplacement)
        }
    }

    func clearDraft() {
        coordinator?.clearDraft()
    }

    func replaceDraft(_ text: String) {
        guard let coordinator else {
            pendingDraftReplacement = text
            return
        }
        coordinator.replaceDraft(with: text)
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
    var rejectsAttachmentPaste: Bool = false
    var onFocusHandled: () -> Void
    /// Returns whether the message was accepted, so the editor only clears
    /// itself when the draft was actually sent or queued.
    var onSendMessage: (String) -> Bool
    var onPasteImage: ((Data, String) -> Void)? = nil
    var onPasteFile: ((ManagedStagedFile) -> Void)? = nil
    var onPasteFileError: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = PastingTextView()
        textView.allowsImagePaste = allowsImagePaste
        textView.rejectsAttachmentPaste = rejectsAttachmentPaste
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
        context.coordinator.currentTextSnapshot = text

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

        handle?.attach(context.coordinator)
        context.coordinator.refreshAccessibility(textView)
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        handle?.attach(context.coordinator)
        if let pastingView = uiView as? PastingTextView {
            pastingView.allowsImagePaste = allowsImagePaste
            pastingView.rejectsAttachmentPaste = rejectsAttachmentPaste
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
        if let replacement = context.coordinator.draftReplacement {
            if text == replacement.replaced {
                text = replacement.replacement
                self.text = replacement.replacement
            } else if text != replacement.replacement {
                context.coordinator.draftReplacement = nil
            }
        }

        if text.isEmpty && !isCurrentlyEditing && uiView.textColor != .lightGray {
            uiView.text = placeholderText
            uiView.textColor = .lightGray
            context.coordinator.currentTextSnapshot = ""
        } else if text.isEmpty && isCurrentlyEditing {
            if uiView.text.isEmpty && uiView.textColor == .lightGray {
                uiView.text = ""
                context.coordinator.currentTextSnapshot = ""
                uiView.textColor = UIColor { traitCollection in
                    return traitCollection.userInterfaceStyle == .dark ? .white : .black
                }
            } else if !uiView.text.isEmpty && uiView.textColor != .lightGray {
                let snapshot = context.coordinator.immutableTextSnapshot(from: uiView)
                context.coordinator.currentTextSnapshot = snapshot
                self.text = snapshot
            }
        } else if !text.isEmpty && uiView.textColor == .lightGray {
            uiView.text = text
            context.coordinator.currentTextSnapshot = text
            uiView.textColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark ? .white : .black
            }
        } else if !text.isEmpty && context.coordinator.currentTextSnapshot != text && uiView.textColor != .lightGray {
            uiView.text = text
            context.coordinator.currentTextSnapshot = text
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
        var currentTextSnapshot = ""
        /// The draft text at the moment `clearDraft` ran. While streaming, the
        /// view model publishes on every token, so a render transaction whose
        /// state snapshot predates the send can reach `updateUIView` after the
        /// clear, still carrying the old draft in the binding. That value must
        /// be recognized and ignored or it gets written back into the emptied
        /// editor and then resynced into the binding, undoing the clear.
        var clearedDraft: String?
        var draftReplacement: (replaced: String, replacement: String)?
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
            draftReplacement = nil
            clearedDraft = immutableTextSnapshot(from: textView)
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
            currentTextSnapshot = ""
            parent.textHeight = MessageInputView.Layout.defaultHeight
            refreshAccessibility(textView)
        }

        func replaceDraft(with text: String) {
            guard let textView else { return }
            let replacedDraft = parent.text
            clearedDraft = nil
            draftReplacement = (replacedDraft, text)
            textView.text = text
            textView.textColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark ? .white : .black
            }
            parent.text = text
            currentTextSnapshot = text
            textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
            parent.textHeight = measuredHeight(for: textView)
            refreshAccessibility(textView)
        }

        /// Returns the editor height for the current draft, avoiding repeated
        /// full-document TextKit layout: results are cached per text/width/font
        /// so keyboard-driven SwiftUI updates don't re-measure an unchanged
        /// draft, and drafts that trivially exceed the height cap skip
        /// measurement entirely.
        func measuredHeight(for textView: UITextView) -> CGFloat {
            let text = currentTextSnapshot
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
            if isShowingPlaceholder {
                textView.accessibilityValue = ""
            } else if UIAccessibility.isVoiceOverRunning {
                textView.accessibilityValue = immutableTextSnapshot(from: textView)
            } else {
                textView.accessibilityValue = nil
            }
        }

        func immutableTextSnapshot(from textView: UITextView) -> String {
            NSString(string: textView.text ?? "") as String
        }

        func textView(_ textView: UITextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
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
            
            return true
        }
        
        func textViewDidChange(_ textView: UITextView) {
            // Only update if the text is not the placeholder
            if textView.textColor != .lightGray {
                let snapshot = immutableTextSnapshot(from: textView)
                currentTextSnapshot = snapshot
                parent.text = snapshot
                
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
                currentTextSnapshot = ""
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
    var rejectsAttachmentPaste = false
    var onPasteImage: ((Data, String) -> Void)?
    var onPasteFile: ((ManagedStagedFile) -> Void)?
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
            if rejectsAttachmentPaste {
                let state = pasteboardState()
                if state.hasImages || state.hasFileURLs {
                    return false
                }
            }
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

        if rejectsAttachmentPaste {
            let state = pasteboardState()
            if state.hasImages || state.hasFileURLs {
                return
            }
        }

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

    /// Copies a pasted file into the app's managed staging directory so the attachment
    /// pipeline can read it after the pasteboard's access window closes.
    /// Oversized files are rejected up front: the pipeline would refuse them
    /// anyway, and copying or reading them first would waste disk and memory.
    private func importPastedFile(url: URL, onPasteFile: (ManagedStagedFile) -> Void) {
        let fileName = url.lastPathComponent
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let handle = try ManagedFileStore.shared.stage(sourceURL: url, fileName: fileName)
            onPasteFile(handle)
        } catch {
            onPasteFileError?(error.localizedDescription)
        }
    }
} 
