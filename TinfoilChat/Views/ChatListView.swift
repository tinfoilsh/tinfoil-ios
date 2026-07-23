//
//  ChatListView.swift
//  TinfoilChat
//
//  UITableView-based chat list wrapper
//

import SwiftUI

struct ChatListView: View {
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Binding var messageText: String
    @ObservedObject private var recoveryDraftStore = ChatRecoveryDraftStore.shared

    @State private var isAtBottom = true
    @State private var userHasScrolled = false
    @State private var isInputExpanded = false
    @State private var showPromptLibrary = false
    @State private var isKeyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollTrigger = UUID()
    @State private var scrollToUserTrigger = UUID()
    @State private var tableOpacity = 1.0
    @State private var archivedMessagesStartIndex = 0

    private var pendingRecoveryTurnIds: Set<String> {
        Set((viewModel.currentChat?.pendingRecoveries ?? []).map(\.turnId))
    }

    private var recoveryDraftTurnIds: Set<String> {
        let chatId = viewModel.currentChat?.id
        return Set(recoveryDraftStore.drafts.keys.compactMap { key in
            key.chatId == chatId && pendingRecoveryTurnIds.contains(key.turnId)
                ? key.turnId
                : nil
        })
    }

    private var messages: [Message] {
        guard let chatId = viewModel.currentChat?.id else {
            return viewModel.messages
        }
        return messagesApplyingRecoveryDrafts(
            viewModel.messages,
            chatId: chatId,
            pendingTurnIds: pendingRecoveryTurnIds,
            drafts: recoveryDraftStore.drafts
        )
    }

    /// Token estimation walks every message, so the result is cached and
    /// refreshed only when the conversation, model, or message count changes
    /// instead of on every body evaluation during streaming.
    private func refreshArchivedMessagesStartIndex() {
        let persistedMessages = viewModel.messages
        let persistedStartIndex = TokenEstimation.findContextStartIndex(
            messages: persistedMessages,
            budgetTokens: TokenEstimation.contextTokenBudget(viewModel.currentModel.contextWindow)
        )
        guard persistedMessages.indices.contains(persistedStartIndex) else {
            archivedMessagesStartIndex = 0
            return
        }
        let boundaryMessageId = persistedMessages[persistedStartIndex].id
        archivedMessagesStartIndex = messages.firstIndex {
            $0.id == boundaryMessageId
        } ?? persistedStartIndex
    }

    var body: some View {
        MessageTableView(
            messages: messages,
            recoveryDraftTurnIds: recoveryDraftTurnIds,
            archivedMessagesStartIndex: archivedMessagesStartIndex,
            isDarkMode: isDarkMode,
            isLoading: isLoading,
            onRequestSignIn: onRequestSignIn,
            viewModel: viewModel,
            isAtBottom: $isAtBottom,
            userHasScrolled: $userHasScrolled,
            scrollTrigger: scrollTrigger,
            scrollToUserTrigger: scrollToUserTrigger,
            tableOpacity: $tableOpacity,
            keyboardHeight: keyboardHeight
        )
        .opacity(tableOpacity)
        .background(Color.chatBackground(isDarkMode: isDarkMode))
        .overlay(alignment: .bottom) {
            if !isAtBottom && !messages.isEmpty && !isKeyboardVisible {
                Group {
                    if #available(iOS 26, *) {
                        Button(action: {
                            userHasScrolled = false
                            viewModel.isScrollInteractionActive = false
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
                            userHasScrolled = false
                            viewModel.isScrollInteractionActive = false
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if messages.isEmpty && !isInputExpanded && !isKeyboardVisible {
                    PromptSuggestionsBar(
                        viewModel: viewModel,
                        onOpenLibrary: { showPromptLibrary = true }
                    )
                    .transition(.opacity)
                }
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
                .environmentObject(viewModel.authManager ?? AuthManager())
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
        .onAppear {
            setupKeyboardObservers()
            refreshArchivedMessagesStartIndex()
            pruneRecoveryDrafts()
        }
        .onDisappear {
            removeKeyboardObservers()
            viewModel.isScrollInteractionActive = false
        }
        .onChange(of: viewModel.currentModel.id) { _, _ in
            refreshArchivedMessagesStartIndex()
        }
        .onChange(of: messages.count) { oldCount, newCount in
            refreshArchivedMessagesStartIndex()
            if newCount > oldCount {
                let newMessages = messages.suffix(newCount - oldCount)
                let hasUserMessage = newMessages.contains { $0.role == .user }
                let wasInitialLoad = oldCount == 0

                if hasUserMessage || wasInitialLoad {
                    userHasScrolled = false
                    viewModel.isScrollInteractionActive = false
                    if hasUserMessage && viewModel.isLoading {
                        scrollToUserTrigger = UUID()
                    } else {
                        scrollTrigger = UUID()
                    }
                }
            }
        }
        .onChange(of: pendingRecoveryTurnIds) { _, _ in
            pruneRecoveryDrafts()
        }
        .onChange(of: viewModel.currentChat?.createdAt) { _, _ in
            refreshArchivedMessagesStartIndex()
            pruneRecoveryDrafts()
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false

            let isNewEmptyChat = viewModel.currentChat?.isBlankChat ?? true

            if !isNewEmptyChat {
                tableOpacity = 0
                scrollTrigger = UUID()
                isAtBottom = true
            } else {
                tableOpacity = 1.0
                isAtBottom = true
            }
        }
        .onChange(of: viewModel.scrollToBottomTrigger) { _, _ in
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false
            scrollTrigger = UUID()
        }
        .onChange(of: viewModel.scrollToUserMessageTrigger) { _, _ in
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false
            scrollToUserTrigger = UUID()
        }
    }

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                isKeyboardVisible = true
                self.keyboardHeight = keyboardFrame.height
            }
        }

        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            isKeyboardVisible = false
            keyboardHeight = 0
        }
    }

    private func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func pruneRecoveryDrafts() {
        guard let chatId = viewModel.currentChat?.id else { return }
        recoveryDraftStore.prune(
            chatId: chatId,
            retaining: pendingRecoveryTurnIds
        )
    }
}
