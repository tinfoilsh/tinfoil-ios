//
//  ChatListView.swift
//  TinfoilChat
//
//  UITableView-based chat list wrapper
//

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var authManager: AuthManager
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Binding var messageText: String

    @State private var isAtBottom = true
    @State private var isInputExpanded = false
    @State private var showPromptLibrary = false
    @State private var showSafeguardsSettings = false
    @State private var isKeyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollTrigger = UUID()
    @State private var scrollToUserTrigger = UUID()
    @State private var tableOpacity = 1.0
    /// The first message shown, by which messages loaded before it are told
    /// apart from messages added after the last.
    @State private var shownFirstMessageId: String?
    /// A chat that opens stays behind the loading spinner until its messages
    /// have been laid out and scrolled into place.
    @State private var isPlacingOpenedChat = false

    private var isCurrentChatReadOnly: Bool {
        viewModel.isCurrentChatSafeguardFlagged
    }

    private var isShowingChatLoading: Bool {
        viewModel.hydratingChatId != nil || (isPlacingOpenedChat && tableOpacity == 0)
    }

    private var messages: [Message] {
        viewModel.messages
    }

    var body: some View {
        TranscriptObserver(transcript: viewModel.transcript) {
            MessageTableView(
                messages: messages,
                isDarkMode: isDarkMode,
                isLoading: isLoading,
                onRequestSignIn: onRequestSignIn,
                viewModel: viewModel,
                isAtBottom: $isAtBottom,
                scrollTrigger: scrollTrigger,
                scrollToUserTrigger: scrollToUserTrigger,
                tableOpacity: $tableOpacity,
                keyboardHeight: keyboardHeight
            )
        }
        .opacity(tableOpacity)
        .background {
            ZStack {
                Color.chatBackground(isDarkMode: isDarkMode)
                if messages.isEmpty {
                    GridTexture(isDarkMode: isDarkMode)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom && !messages.isEmpty && !isKeyboardVisible {
                Group {
                    if #available(iOS 26, *) {
                        Button(action: {
                            scrollTrigger = UUID()
                        }) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: Constants.UI.scrollToBottomButtonSize, height: Constants.UI.scrollToBottomButtonSize)
                        }
                        .buttonStyle(.glass)
                        .clipShape(Circle())
                        .accessibilityLabel(Constants.Accessibility.scrollToLatestMessage)
                    } else {
                        Button(action: {
                            scrollTrigger = UUID()
                        }) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.gray.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(Constants.Accessibility.scrollToLatestMessage)
                    }
                }
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        // Covers the messages only: the input stays in place below it.
        .overlay {
            if isShowingChatLoading || viewModel.chatHydrationError != nil {
                VStack(spacing: 12) {
                    if isShowingChatLoading {
                        ProgressView()
                    }
                    if let error = viewModel.chatHydrationError {
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if viewModel.chatHydrationError != nil && viewModel.canRetryFailedChatHydration {
                        Button("Try Again") {
                            viewModel.retryFailedChatHydration()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.chatBackground(isDarkMode: isDarkMode))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(viewModel.chatHydrationError ?? "Loading conversation")
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // A chat that is opening, or failed to, is not a new chat.
                if messages.isEmpty && !isShowingChatLoading && viewModel.chatHydrationError == nil
                    && !isInputExpanded && !isKeyboardVisible && !isCurrentChatReadOnly {
                    PromptSuggestionsBar(
                        viewModel: viewModel,
                        onOpenLibrary: { showPromptLibrary = true }
                    )
                    .transition(.opacity)

                    if !authManager.isAuthenticated {
                        Text("By using this chat, you agree to our [Terms of Service](\(Constants.Legal.termsOfServiceURL.absoluteString)) and [Privacy Policy](\(Constants.Legal.privacyPolicyURL.absoluteString)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .tint(Color.adaptiveAccent)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                }
                if authManager.isAuthenticated, let chatId = viewModel.currentChat?.id {
                    SafeguardFlagBanner(
                        store: authManager.safeguards,
                        chatId: chatId,
                        onOpenSettings: { showSafeguardsSettings = true }
                    )
                    .id(chatId)
                }
                if !isCurrentChatReadOnly {
                    MessageQueueView(
                        queue: viewModel.queuedMessages,
                        isDarkMode: isDarkMode,
                        onRemove: { viewModel.removeQueuedMessage(id: $0) }
                    )
                    MessageInputView(
                        messageText: $messageText,
                        viewModel: viewModel,
                        isInputExpanded: $isInputExpanded,
                        isKeyboardVisible: isKeyboardVisible
                    )
                    .disabled(isForkingCurrentChat)
                    .environmentObject(viewModel.authManager ?? AuthManager())
                }
            }
            .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                HStack {
                    Spacer()
                    view.frame(maxWidth: 600)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showPromptLibrary) {
            NavigationStack {
                PromptLibraryView(
                    activePresetId: viewModel.currentChat?.promptPresetId,
                    onSelectPreset: { viewModel.setPromptPreset($0) }
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showPromptLibrary = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showSafeguardsSettings) {
            NavigationStack {
                SafeguardsSettingsView(
                    store: authManager.safeguards,
                    onOpenChat: { showSafeguardsSettings = false }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showSafeguardsSettings = false }
                    }
                }
            }
        }
        .task(id: viewModel.hasActiveStreams) {
            guard !viewModel.hasActiveStreams, authManager.isAuthenticated, !Task.isCancelled else { return }
            await authManager.safeguards.refresh()
        }
        .onChange(of: isCurrentChatReadOnly, initial: true) { _, isReadOnly in
            guard isReadOnly else { return }
            messageText = ""
            isInputExpanded = false
            isKeyboardVisible = false
            keyboardHeight = 0
            showPromptLibrary = false
            viewModel.shouldFocusInput = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                isKeyboardVisible = true
                keyboardHeight = keyboardFrame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
            keyboardHeight = 0
        }
        .onChange(of: messages.count) { oldCount, newCount in
            let previousFirstId = shownFirstMessageId
            shownFirstMessageId = messages.first?.id
            // Messages loaded before those shown leave the reader in place.
            if oldCount > 0, let previousFirstId, messages.first?.id != previousFirstId,
               messages.contains(where: { $0.id == previousFirstId }) {
                return
            }
            if newCount > oldCount {
                let newMessages = messages.suffix(newCount - oldCount)
                let hasUserMessage = newMessages.contains { $0.role == .user }
                let wasInitialLoad = oldCount == 0

                if hasUserMessage || wasInitialLoad {
                    if hasUserMessage && viewModel.isLoading {
                        scrollToUserTrigger = UUID()
                    } else {
                        // A chat's messages arriving after it opened stay
                        // hidden until the scroll to the end has placed them.
                        if wasInitialLoad { tableOpacity = 0 }
                        scrollTrigger = UUID()
                    }
                }
            }
        }
        // Keyed off the chat id: the open chat is rebuilt with every change
        // to it, which must not read as a chat switch, since this handler
        // force-scrolls to the bottom.
        .onChange(of: viewModel.currentChat?.id) { oldId, _ in
            // Another chat may open with as many messages as the one before,
            // which changes no count; older messages loaded into it are told
            // from new ones by its own first message.
            shownFirstMessageId = messages.first?.id
            // A new chat's first message gives the chat its id: the same
            // conversation stays on screen, positioned by the message count
            // change that came with it.
            if oldId?.isEmpty ?? true, viewModel.isNewChatsFirstTurn { return }

            // A chat still opening has no messages yet, and stays hidden
            // until they have loaded and been placed.
            let isNewEmptyChat = (viewModel.currentChat?.isBlankChat ?? true) && !viewModel.isOpeningChat

            if !isNewEmptyChat {
                tableOpacity = 0
                scrollTrigger = UUID()
                isAtBottom = true
            } else {
                tableOpacity = 1.0
                isAtBottom = true
            }
        }
        // The table is hidden while a chat opens, and shows once it has
        // placed the messages the chat opened with. A chat that opened with
        // none, or failed to open, has nothing to place.
        .onChange(of: viewModel.hydratingChatId) { _, loadingId in
            if loadingId != nil {
                isPlacingOpenedChat = true
                tableOpacity = 0
            } else if messages.isEmpty {
                isPlacingOpenedChat = false
                tableOpacity = 1.0
            } else {
                scrollTrigger = UUID()
            }
        }
        .onChange(of: tableOpacity) { _, opacity in
            if opacity > 0 { isPlacingOpenedChat = false }
        }
        .onChange(of: viewModel.scrollToBottomTrigger) { _, _ in
            scrollTrigger = UUID()
        }
        .onChange(of: viewModel.scrollToUserMessageTrigger) { _, _ in
            scrollToUserTrigger = UUID()
        }
        .overlay {
            if isForkingCurrentChat {
                forkingOverlay
            }
        }
    }

    private var isForkingCurrentChat: Bool {
        viewModel.forkingChatId != nil && viewModel.forkingChatId == viewModel.currentChat?.id
    }

    /// Dims the transcript and blocks interaction while a fork of the
    /// current chat is landing, so the user cannot edit or send into the
    /// source until the fork has been selected.
    private var forkingOverlay: some View {
        ZStack {
            Color.chatBackground(isDarkMode: isDarkMode)
                .opacity(Constants.ChatFork.overlayDimOpacity)
                .ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                Text(Constants.ChatFork.overlayLabel)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.chatBackground(isDarkMode: isDarkMode))
                    .shadow(radius: 8, y: 2)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Constants.ChatFork.overlayLabel)
        .accessibilityAddTraits(.updatesFrequently)
        .transition(.opacity)
        .animation(.easeInOut(duration: Constants.ChatFork.overlayFadeSeconds), value: viewModel.forkingChatId)
    }
}

/// Draws the chat table again as the open chat's transcript changes, which
/// the views around it do not show.
private struct TranscriptObserver<Content: View>: View {
    @ObservedObject var transcript: TranscriptChanges
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
